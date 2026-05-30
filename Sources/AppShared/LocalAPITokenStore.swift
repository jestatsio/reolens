import Foundation
import Security

/// Device-local storage + generation for the Local API bearer token.
///
/// The token is a credential (AGENTS.md §4), so it lives in the Keychain and
/// is **never** synced (`kSecAttrSynchronizable: false`) — each Mac that runs
/// the API has its own token. It's shown to the user once when generated and
/// can be regenerated, which invalidates the old one on the next server start.
///
/// Kept separate from the per-camera password store (`Keychain`, keyed by
/// camera UUID): this is a single, app-scoped secret under its own service.
public enum LocalAPITokenStore {
    private static let service = "com.reolens.localAPIToken"
    private static let account = "default"

    /// The current token, or nil if none has been generated yet.
    public static func current() -> String? { read() }

    /// Generate, persist, and return a fresh token, replacing any existing one.
    @discardableResult
    public static func regenerate() -> String? {
        let token = generateToken()
        return write(token) ? token : nil
    }

    /// Return the existing token, generating one on first use.
    @discardableResult
    public static func ensure() -> String? {
        if let existing = read() { return existing }
        return regenerate()
    }

    /// Remove the stored token.
    public static func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    /// 32 bytes of CSPRNG entropy, URL-safe base64 (no padding). Pure — safe
    /// to unit-test for format and uniqueness.
    public static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            // CSPRNG unavailable (documented but extremely rare). Never emit a
            // zero/predictable token — fall back to UUIDs, which are also
            // CSPRNG-backed (security review M2).
            return (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Keychain I/O

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func write(_ token: String) -> Bool {
        guard let data = token.data(using: .utf8) else { return false }
        clear()
        var attrs = baseQuery()
        attrs[kSecAttrSynchronizable as String] = kCFBooleanFalse
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    private static func read() -> String? {
        var query = baseQuery()
        // Match only the device-local (non-synced) item we write — never an
        // iCloud-synced one (security review M3).
        query[kSecAttrSynchronizable as String] = kCFBooleanFalse
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else { return nil }
        return token
    }
}
