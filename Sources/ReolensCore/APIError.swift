import Foundation

/// A structured, machine-readable API error.
///
/// This is the only error shape the HTTP facade ever serializes. Per AGENTS.md
/// §3 / §11, `message` must never carry credentials, tokens, or full URLs with
/// auth — it is a short, human-readable summary safe to show a user or log at
/// `.public`. The `code` is a stable, machine-matchable token; consumers branch
/// on `code`, not on `message` text.
public struct APIError: Sendable, Codable, Hashable, Error {
    /// Stable, machine-readable identifier, e.g. `"camera_not_found"`.
    public let code: String
    /// Human-readable summary. No secrets, no URLs with auth.
    public let message: String
    /// The HTTP status the facade should return for this error.
    public let status: Int

    public init(code: String, message: String, status: Int) {
        self.code = code
        self.message = message
        self.status = status
    }
}

public extension APIError {
    /// 400 — the request was malformed (bad path param, body, or query).
    static func badRequest(_ message: String = "Bad request") -> APIError {
        APIError(code: "bad_request", message: message, status: 400)
    }

    /// 401 — missing or invalid bearer token.
    static func unauthorized(_ message: String = "Missing or invalid API token") -> APIError {
        APIError(code: "unauthorized", message: message, status: 401)
    }

    /// 403 — authenticated but not permitted (e.g. peer outside the allowed scope).
    static func forbidden(_ message: String = "Forbidden") -> APIError {
        APIError(code: "forbidden", message: message, status: 403)
    }

    /// 404 — no camera with that id is known to this instance.
    static func cameraNotFound(_ id: CameraID) -> APIError {
        APIError(code: "camera_not_found", message: "No camera with id \(id)", status: 404)
    }

    /// 404 — the camera exists but has no such channel.
    static func channelNotFound(channel: Int) -> APIError {
        APIError(code: "channel_not_found", message: "No channel \(channel)", status: 404)
    }

    /// 404 — generic not-found for any other resource (e.g. a recording id).
    static func notFound(_ message: String = "Not found") -> APIError {
        APIError(code: "not_found", message: message, status: 404)
    }

    /// 502 — the camera could not be reached or rejected the upstream request.
    /// The underlying transport error is logged separately (redacted); the
    /// user-facing message stays generic.
    static func upstreamUnreachable(_ message: String = "The camera could not be reached") -> APIError {
        APIError(code: "upstream_unreachable", message: message, status: 502)
    }

    /// 501 — a contract endpoint that this build does not implement yet
    /// (e.g. HLS streaming before Phase 5).
    static func notImplemented(_ message: String = "Not implemented") -> APIError {
        APIError(code: "not_implemented", message: message, status: 501)
    }

    /// 500 — an unexpected internal failure. Last resort; prefer a specific code.
    static func server(_ message: String = "Internal error") -> APIError {
        APIError(code: "internal_error", message: message, status: 500)
    }
}
