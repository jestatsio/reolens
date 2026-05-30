import Foundation
import Network
import ReolensCore
import OSLog

private let log = Logger(subsystem: "com.reolens.server", category: "http")

/// The opt-in, LAN-local HTTP facade. Hand-rolled HTTP/1.1 + SSE on
/// `NWListener`, preserving the package's zero-dependency posture.
///
/// One request per connection (no keep-alive); the `/v1/events` route upgrades
/// the connection to a Server-Sent-Events stream. All routing, auth, and error
/// mapping happen in ``APIGateway`` — this type is just byte transport plus
/// peer-scope enforcement.
///
/// `@unchecked Sendable`: it owns an `NWListener` and mutable lifecycle state
/// guarded by serial delivery on its own queue.
public final class ReolensAPIServer: @unchecked Sendable {
    private let gateway: APIGateway
    private let config: ServerConfig
    private let queue = DispatchQueue(label: "com.reolens.server.http", attributes: .concurrent)
    private var listener: NWListener?

    public init(api: any CameraAPI, token: String?, config: ServerConfig = ServerConfig()) {
        self.config = config
        // The facade owns its externally-visible base URL (used to fill MJPEG
        // stream references the adapter can't know).
        let base = "http://localhost:\(config.port)"
        self.gateway = APIGateway(api: api, token: token, publicBaseURL: base)
    }

    /// Start listening. Resolves when the listener is ready (or throws on bind
    /// failure). Pass `ServerConfig(port: 0)` for an OS-assigned port (tests).
    public func start() async throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        let listener: NWListener
        if config.port == 0 {
            listener = try NWListener(using: params)
        } else {
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: config.port)!)
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        self.listener = listener

        let once = OnceFlag()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    log.info("Reolens API server ready")
                    if once.set() { continuation.resume() }
                case .failed(let error):
                    log.error("listener failed: \(String(describing: error), privacy: .public)")
                    if once.set() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    /// The port actually bound (resolves an OS-assigned port). nil before ready.
    public var boundPort: UInt16? { listener?.port?.rawValue }

    // MARK: - Accepting connections

    private func accept(_ connection: NWConnection) {
        guard Self.peerAllowed(connection, scope: config.bindScope) else {
            log.debug("rejected non-LAN peer")
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        let box = ConnectionBox(connection: connection)
        let gateway = self.gateway
        Task {
            await Self.serve(box.connection, gateway: gateway)
        }
    }

    private static func serve(_ connection: NWConnection, gateway: APIGateway) async {
        defer { connection.cancel() }
        do {
            guard let request = try await readRequest(connection) else { return }
            switch await gateway.handle(request) {
            case .response(let response):
                try await connection.sendData(response.serialized())
            case .events(let stream):
                try await streamEvents(connection, stream: stream)
            case .mjpeg(let stream):
                try await streamMJPEG(connection, stream: stream)
            }
        } catch {
            log.debug("connection ended: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Request reading

    private static let maxHeaderBytes = 64 * 1024
    /// Ceiling on a request body. Generous for PTZ/settings JSON; bounds the
    /// per-connection allocation a forged `Content-Length` could otherwise pin
    /// (security review H1).
    private static let maxBodyBytes = 1024 * 1024

    private static func readRequest(_ connection: NWConnection) async throws -> HTTPRequest? {
        var buffer = Data()
        while true {
            if let range = buffer.range(of: HTTPRequestParser.headerTerminator) {
                let headData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                guard let head = HTTPRequestParser.parseHead(headData) else { return nil }
                guard head.contentLength <= maxBodyBytes else { return nil }
                var body = buffer.subdata(in: range.upperBound..<buffer.endIndex)
                while body.count < head.contentLength {
                    let (chunk, isComplete) = try await connection.receiveData(maxLength: maxHeaderBytes)
                    body.append(chunk)
                    if isComplete { break }
                }
                return HTTPRequest(method: head.method, path: head.path, query: head.query, headers: head.headers, body: body)
            }
            if buffer.count > maxHeaderBytes { return nil }
            let (chunk, isComplete) = try await connection.receiveData(maxLength: maxHeaderBytes)
            buffer.append(chunk)
            if isComplete && buffer.range(of: HTTPRequestParser.headerTerminator) == nil {
                return nil   // closed before a complete request head
            }
        }
    }

    // MARK: - SSE

    private static func streamEvents(_ connection: NWConnection, stream: AsyncStream<EventResource>) async throws {
        let head = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: text/event-stream\r\n"
            + "Cache-Control: no-cache\r\n"
            + "Connection: keep-alive\r\n\r\n"
        try await connection.sendData(Data(head.utf8))
        for await event in stream {
            guard let json = try? APIJSON.encoder.encode(event),
                  let line = String(data: json, encoding: .utf8) else { continue }
            do {
                try await connection.sendData(Data("data: \(line)\n\n".utf8))
            } catch {
                break   // consumer disconnected
            }
        }
    }

    /// Serve a JPEG frame stream as `multipart/x-mixed-replace` — the format
    /// browsers and Home Assistant render as a live MJPEG video.
    private static func streamMJPEG(_ connection: NWConnection, stream: AsyncStream<Data>) async throws {
        let boundary = "reolensframe"
        let head = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: multipart/x-mixed-replace; boundary=\(boundary)\r\n"
            + "Cache-Control: no-cache\r\n"
            + "Connection: close\r\n\r\n"
        try await connection.sendData(Data(head.utf8))
        for await frame in stream {
            var part = Data("--\(boundary)\r\nContent-Type: image/jpeg\r\nContent-Length: \(frame.count)\r\n\r\n".utf8)
            part.append(frame)
            part.append(Data("\r\n".utf8))
            do {
                try await connection.sendData(part)
            } catch {
                break   // consumer disconnected
            }
        }
    }

    // MARK: - Peer scope

    static func peerAllowed(_ connection: NWConnection, scope: ServerConfig.BindScope) -> Bool {
        // Fail closed on anything we can't read as a concrete IP host:port. A
        // non-hostPort or name-based peer is not provably LAN-local — and a
        // hostname can't be safely accepted (DNS rebinding), so we never trust
        // `.name` (security review H2/H3).
        guard case let .hostPort(host, _) = connection.endpoint else { return false }
        switch host {
        case .ipv4(let address): return isAllowed(ip: "\(address)", scope: scope)
        case .ipv6(let address): return isAllowed(ip: "\(address)", scope: scope)
        case .name: return false
        @unknown default: return false
        }
    }

    static func isAllowed(ip: String, scope: ServerConfig.BindScope) -> Bool {
        let clean = ip.split(separator: "%").first.map(String.init) ?? ip   // strip IPv6 zone id
        if isLoopback(clean) { return true }
        if scope == .loopback { return false }
        return isPrivate(clean)
    }

    static func isLoopback(_ ip: String) -> Bool {
        if ip.lowercased().hasPrefix("::ffff:") {
            return isLoopback(String(ip.dropFirst("::ffff:".count)))
        }
        return ip == "::1" || ip.hasPrefix("127.")
    }

    static func isPrivate(_ ip: String) -> Bool {
        // IPv4-mapped IPv6 (e.g. ::ffff:10.0.0.1) — evaluate the embedded IPv4
        // so a LAN peer surfaced in mapped form isn't falsely rejected (M1).
        if ip.lowercased().hasPrefix("::ffff:") {
            return isPrivate(String(ip.dropFirst("::ffff:".count)))
        }
        if ip.hasPrefix("10.") || ip.hasPrefix("192.168.") || ip.hasPrefix("169.254.") { return true }
        if ip.hasPrefix("172.") {
            let parts = ip.split(separator: ".")
            if parts.count > 1, let second = Int(parts[1]), (16...31).contains(second) { return true }
        }
        let lower = ip.lowercased()
        return lower.hasPrefix("fd") || lower.hasPrefix("fc") || lower.hasPrefix("fe80")
    }
}
