import Foundation

/// The JSON envelope every resource endpoint returns.
///
/// Aligns with the repository's `patterns.md` "consistent envelope" rule:
/// a `data` payload on success, an `error` on failure, and `meta` for
/// collection metadata (pagination, counts). Exactly one of `data` / `error`
/// is non-nil for a given response.
///
/// Binary endpoints (snapshot JPEG bytes) and the SSE event stream do **not**
/// use this envelope — they emit raw bytes / bare event JSON respectively.
public struct APIResponse<Payload: Codable & Sendable>: Codable, Sendable {
    public let data: Payload?
    public let error: APIError?
    public let meta: APIMeta?

    public init(data: Payload? = nil, error: APIError? = nil, meta: APIMeta? = nil) {
        self.data = data
        self.error = error
        self.meta = meta
    }

    /// Wrap a successful payload, optionally with collection metadata.
    public static func success(_ payload: Payload, meta: APIMeta? = nil) -> APIResponse<Payload> {
        APIResponse(data: payload, error: nil, meta: meta)
    }
}

/// Collection / pagination metadata carried alongside a `data` payload.
public struct APIMeta: Codable, Sendable, Hashable {
    /// Number of items in `data` when it is a collection.
    public var count: Int?
    /// Opaque cursor to pass back as `?cursor=` to fetch the next page, or nil
    /// when there are no more results.
    public var nextCursor: String?

    public init(count: Int? = nil, nextCursor: String? = nil) {
        self.count = count
        self.nextCursor = nextCursor
    }
}
