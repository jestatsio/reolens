import Foundation
import ReolensCore

/// Shared JSON coders for the API. ISO-8601 dates and unescaped slashes so URLs
/// in payloads stay readable.
enum APIJSON {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// A parsed inbound HTTP request. Header keys are lowercased.
public struct HTTPRequest: Sendable {
    public let method: String
    /// Path only (no query string), percent-decoded.
    public let path: String
    public let query: [String: String]
    public let headers: [String: String]
    public let body: Data

    public init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:], body: Data = Data()) {
        self.method = method.uppercased()
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }

    /// Case-insensitive header lookup.
    public func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// Non-empty path segments, e.g. `/v1/cameras/X` → `["v1","cameras","X"]`.
    public var pathSegments: [String] {
        path.split(separator: "/").map(String.init)
    }
}

/// An outbound HTTP response.
public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int = 200, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

public extension HTTPResponse {
    /// JSON success envelope (`{ "data": …, "meta": … }`).
    static func envelope<T: Codable & Sendable>(_ data: T, meta: APIMeta? = nil, status: Int = 200) -> HTTPResponse {
        let payload = APIResponse(data: data, error: nil, meta: meta)
        let body = (try? APIJSON.encoder.encode(payload)) ?? Data()
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: body)
    }

    /// JSON error envelope (`{ "error": … }`) with the error's HTTP status.
    static func failure(_ error: APIError) -> HTTPResponse {
        struct ErrorEnvelope: Encodable { let error: APIError }
        let body = (try? APIJSON.encoder.encode(ErrorEnvelope(error: error))) ?? Data()
        return HTTPResponse(status: error.status, headers: ["Content-Type": "application/json"], body: body)
    }

    /// Raw bytes with a content type (snapshots, downloads).
    static func bytes(_ data: Data, contentType: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": contentType], body: data)
    }

    /// Arbitrary JSON value (used for `/v1/openapi.json`).
    static func json(_ value: some Encodable, status: Int = 200) -> HTTPResponse {
        let body = (try? APIJSON.encoder.encode(value)) ?? Data()
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: body)
    }

    /// `202 Accepted` with no body (PTZ and other fire-and-forget commands).
    static func accepted() -> HTTPResponse { HTTPResponse(status: 202) }

    /// Serialize to HTTP/1.1 wire bytes. Adds `Content-Length` and closes the
    /// connection after the response (no keep-alive — one request per
    /// connection keeps the embedded server small).
    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reasonPhrase(status))\r\n"
        var allHeaders = headers
        allHeaders["Content-Length"] = String(body.count)
        allHeaders["Connection"] = "close"
        for (key, value) in allHeaders.sorted(by: { $0.key < $1.key }) {
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        case 502: "Bad Gateway"
        default: "Status \(status)"
        }
    }
}
