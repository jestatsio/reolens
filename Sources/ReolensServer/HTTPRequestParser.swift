import Foundation

/// Minimal HTTP/1.1 request-head parser. Parses the request line + headers; the
/// body is read separately by the connection loop using `Content-Length`.
///
/// Deliberately small: no chunked transfer-encoding, no trailers, no
/// continuation lines. That covers curl, URLSession, and Home Assistant, which
/// is the entire consumer set for a LAN-local API.
enum HTTPRequestParser {

    struct Head {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]

        var contentLength: Int { Int(headers["content-length"] ?? "") ?? 0 }
    }

    /// The CRLFCRLF terminator that ends the header block.
    static let headerTerminator = Data("\r\n\r\n".utf8)

    /// Parse the header block (bytes up to, not including, the terminator).
    static func parseHead(_ data: Data) -> Head? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0]).uppercased()
        let (path, query) = splitTarget(String(parts[1]))

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        return Head(method: method, path: path, query: query, headers: headers)
    }

    /// Split a request target into a percent-decoded path and a decoded query.
    static func splitTarget(_ target: String) -> (path: String, query: [String: String]) {
        guard let qIndex = target.firstIndex(of: "?") else {
            return (decode(target), [:])
        }
        let path = decode(String(target[..<qIndex]))
        let queryString = target[target.index(after: qIndex)...]
        var query: [String: String] = [:]
        for pair in queryString.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            let key = decode(String(kv[0]))
            let raw = kv.count > 1 ? String(kv[1]) : ""
            query[key] = decode(raw.replacingOccurrences(of: "+", with: " "))
        }
        return (path, query)
    }

    private static func decode(_ value: String) -> String {
        value.removingPercentEncoding ?? value
    }
}
