import Foundation
import Network
import Testing
import ReolensCore
@testable import ReolensServer

@Suite("HTTPRequestParser")
struct HTTPRequestParserTests {
    @Test("parses method, path, query, headers")
    func parseHead() throws {
        let raw = "POST /v1/cameras/CAM-1/channels/0/ptz?quality=main HTTP/1.1\r\n"
            + "Host: localhost\r\n"
            + "Authorization: Bearer abc\r\n"
            + "Content-Length: 12\r\n"
        let head = try #require(HTTPRequestParser.parseHead(Data(raw.utf8)))
        #expect(head.method == "POST")
        #expect(head.path == "/v1/cameras/CAM-1/channels/0/ptz")
        #expect(head.query["quality"] == "main")
        #expect(head.headers["authorization"] == "Bearer abc")
        #expect(head.contentLength == 12)
    }

    @Test("percent-decodes the path and query")
    func decoding() {
        let (path, query) = HTTPRequestParser.splitTarget("/v1/cameras/a%20b?name=front%20door")
        #expect(path == "/v1/cameras/a b")
        #expect(query["name"] == "front door")
    }
}

@Suite("Peer scope")
struct PeerScopeTests {
    @Test("loopback is always allowed")
    func loopback() {
        #expect(ReolensAPIServer.isAllowed(ip: "127.0.0.1", scope: .loopback))
        #expect(ReolensAPIServer.isAllowed(ip: "::1", scope: .loopback))
    }

    @Test("private LAN allowed only under .lan scope")
    func privateRanges() {
        for ip in ["192.168.1.10", "10.0.0.5", "172.16.4.4"] {
            #expect(ReolensAPIServer.isAllowed(ip: ip, scope: .lan))
            #expect(!ReolensAPIServer.isAllowed(ip: ip, scope: .loopback))
        }
    }

    @Test("public addresses are rejected")
    func publicRejected() {
        #expect(!ReolensAPIServer.isAllowed(ip: "8.8.8.8", scope: .lan))
        #expect(!ReolensAPIServer.isAllowed(ip: "172.32.0.1", scope: .lan))   // just outside 172.16/12
    }

    @Test("IPv4-mapped IPv6 resolves to its embedded IPv4")
    func mappedIPv6() {
        #expect(ReolensAPIServer.isAllowed(ip: "::ffff:192.168.1.5", scope: .lan))
        #expect(ReolensAPIServer.isAllowed(ip: "::ffff:127.0.0.1", scope: .loopback))
        #expect(!ReolensAPIServer.isAllowed(ip: "::ffff:8.8.8.8", scope: .lan))
    }
}

@Suite("Server end-to-end (loopback)")
struct ServerSmokeTests {

    /// Raw TCP HTTP client — avoids App Transport Security entirely and keeps
    /// the test deterministic.
    private func rawHTTP(port: UInt16, _ raw: String) async throws -> (status: Int, body: Data) {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let once = OnceFlag()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.set() { continuation.resume() }
                case .failed(let error): if once.set() { continuation.resume(throwing: error) }
                default: break
                }
            }
            connection.start(queue: .global())
        }
        defer { connection.cancel() }

        try await connection.sendData(Data(raw.utf8))
        var buffer = Data()
        while true {
            let (chunk, isComplete) = try await connection.receiveData(maxLength: 65_536)
            buffer.append(chunk)
            if isComplete { break }
        }
        guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else { return (0, Data()) }
        let headText = String(data: buffer.subdata(in: buffer.startIndex..<range.lowerBound), encoding: .utf8) ?? ""
        let body = buffer.subdata(in: range.upperBound..<buffer.endIndex)
        let statusLine = headText.components(separatedBy: "\r\n").first ?? ""
        let status = statusLine.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
        return (status, body)
    }

    @Test("serves health, an authed list, and 401s without a token")
    func endToEnd() async throws {
        let server = ReolensAPIServer(
            api: FakeCameraAPI.oneCamera,
            token: "secret",
            config: ServerConfig(port: 0, bindScope: .loopback)
        )
        try await server.start()
        defer { server.stop() }
        let port = try #require(server.boundPort)

        // health requires auth now (no pre-auth fleet enumeration).
        let health = try await rawHTTP(port: port, "GET /v1/health HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer secret\r\nConnection: close\r\n\r\n")
        #expect(health.status == 200)
        let healthNoAuth = try await rawHTTP(port: port, "GET /v1/health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        #expect(healthNoAuth.status == 401)

        let cameras = try await rawHTTP(port: port, "GET /v1/cameras HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer secret\r\nConnection: close\r\n\r\n")
        #expect(cameras.status == 200)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(APIResponse<[CameraResource]>.self, from: cameras.body)
        #expect(decoded.data?.first?.id == "CAM-1")

        let unauth = try await rawHTTP(port: port, "GET /v1/cameras HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        #expect(unauth.status == 401)
    }
}
