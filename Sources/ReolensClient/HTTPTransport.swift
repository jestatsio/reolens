import Foundation

/// A single HTTP request the client wants to make. Deliberately a plain
/// value type (not `URLRequest`) so tests can assert on method, URL,
/// headers, and body without a network (AGENTS.md §12).
public struct ClientRequest: Sendable, Hashable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data

    public init(method: String, url: URL, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }

    /// Case-insensitive header lookup.
    public func header(_ name: String) -> String? {
        headers.first(where: { $0.key.lowercased() == name.lowercased() })?.value
    }
}

/// A completed HTTP response. Header keys are lowercased by the transport.
public struct ClientResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

/// Byte transport for ``RemoteCameraAPI``. The live implementation is
/// ``URLSessionTransport``; tests inject a stub. Mirrors the server side's
/// split where `APIGateway` is pure and only the shell touches sockets.
public protocol HTTPTransport: Sendable {
    /// Perform a request and return the full response.
    func send(_ request: ClientRequest) async throws -> ClientResponse

    /// Perform a request and stream the response body as text lines
    /// (Server-Sent Events). Throws if the connection cannot be made or
    /// the status is not 2xx.
    func streamLines(_ request: ClientRequest) -> AsyncThrowingStream<String, any Error>
}

/// Errors the client raises before/without a usable API response.
public enum ReolensClientError: Error, Sendable, Hashable {
    /// The server could not be reached at all (connection refused, DNS,
    /// timeout). The associated value is a short, credential-free reason.
    case unreachable(String)
    /// The server answered but the body did not match the contract.
    case malformedResponse(String)
}

/// `URLSession`-backed transport. One request per connection matches the
/// server's `Connection: close` behavior; no credential ever appears in a
/// URL (the bearer token rides the `Authorization` header only).
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession
    private let streamingSession: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
            self.streamingSession = session
        } else {
            // Unary calls should fail fast when the server is wedged.
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 60 * 60 * 24
            self.session = URLSession(configuration: config)
            // Streaming (SSE) is the opposite shape: silence between
            // events is normal, so neither timeout may reap an idle
            // stream. The server also sends heartbeat comments, but
            // the client must not depend on their cadence.
            let streamingConfig = URLSessionConfiguration.ephemeral
            streamingConfig.timeoutIntervalForRequest = 60 * 60 * 24
            streamingConfig.timeoutIntervalForResource = 60 * 60 * 24
            self.streamingSession = URLSession(configuration: streamingConfig)
        }
    }

    public func send(_ request: ClientRequest) async throws -> ClientResponse {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: Self.urlRequest(request))
        } catch {
            throw ReolensClientError.unreachable(Self.shortReason(error))
        }
        guard let http = response as? HTTPURLResponse else {
            throw ReolensClientError.malformedResponse("Non-HTTP response")
        }
        return ClientResponse(status: http.statusCode, headers: Self.lowercased(http), body: data)
    }

    public func streamLines(_ request: ClientRequest) -> AsyncThrowingStream<String, any Error> {
        let session = self.streamingSession
        let urlRequest = Self.streamingRequest(request)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    guard let http = response as? HTTPURLResponse else {
                        throw ReolensClientError.malformedResponse("Non-HTTP response")
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        throw ReolensClientError.unreachable("Event stream refused (HTTP \(http.statusCode))")
                    }
                    for try await line in bytes.lines {
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error is ReolensClientError
                        ? error
                        : ReolensClientError.unreachable(Self.shortReason(error)))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Build the streaming variant of a request: same shape, but with
    /// the per-request idle timeout disabled so a quiet SSE stream is
    /// never reaped for silence (also covers injected sessions whose
    /// configuration we do not control).
    static func streamingRequest(_ request: ClientRequest) -> URLRequest {
        var streaming = urlRequest(request)
        streaming.timeoutInterval = .infinity
        return streaming
    }

    private static func urlRequest(_ request: ClientRequest) -> URLRequest {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        if !request.body.isEmpty {
            urlRequest.httpBody = request.body
        }
        return urlRequest
    }

    private static func lowercased(_ response: HTTPURLResponse) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            result[String(describing: key).lowercased()] = String(describing: value)
        }
        return result
    }

    /// Short, URL-free failure summary (AGENTS.md §11: user-visible error
    /// strings never carry URLs).
    static func shortReason(_ error: any Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                return "Cannot reach the Reolens server"
            case .timedOut:
                return "The Reolens server timed out"
            case .notConnectedToInternet, .networkConnectionLost:
                return "Network connection lost"
            default:
                return "Cannot reach the Reolens server"
            }
        }
        return "Cannot reach the Reolens server"
    }
}
