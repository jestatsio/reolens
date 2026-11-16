import Foundation

public extension CameraAPI {
    /// Resolve a user-typed camera selector to a configured camera.
    ///
    /// Shared by the CLI and MCP surfaces (0.10.0) so both accept the
    /// same selectors: an exact camera id, or an exact display name
    /// (case-insensitive). Ambiguous names and unknown selectors throw
    /// typed ``APIError`` values whose messages list camera ids/names
    /// only — never hosts or credentials (AGENTS.md §3).
    func resolveCamera(_ selector: String) async throws -> CameraResource {
        let all = try await cameras()
        if let byID = all.first(where: { $0.id == selector }) {
            return byID
        }
        let byName = all.filter { $0.displayName.caseInsensitiveCompare(selector) == .orderedSame }
        if byName.count == 1, let match = byName.first {
            return match
        }
        if byName.count > 1 {
            let ids = byName.map(\.id).joined(separator: ", ")
            throw APIError.badRequest("Name '\(selector)' matches \(byName.count) cameras; use an id instead: \(ids)")
        }
        throw APIError.cameraNotFound(selector)
    }
}

/// ISO-8601 parsing shared by the client-facing surfaces. Accepts both
/// fractional-second and plain internet-date-time forms, matching the
/// HTTP gateway's query parsing.
public enum APITime {
    /// Parse an ISO-8601 internet date-time (fractional seconds optional).
    public static func parseISO8601(_ value: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }

    /// Format a date as ISO-8601 internet date-time.
    public static func formatISO8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
