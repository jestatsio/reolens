import Foundation
import Testing
import AppShared

@Suite("LocalAPITokenStore")
struct LocalAPITokenStoreTests {

    @Test("Generated tokens are URL-safe, long, and unique")
    func generateToken() {
        let a = LocalAPITokenStore.generateToken()
        let b = LocalAPITokenStore.generateToken()

        // 32 bytes of entropy → ~43 base64url chars.
        #expect(a.count >= 40)
        #expect(a != b)

        // URL-safe base64 with no padding: only [A-Za-z0-9-_], nothing else.
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        #expect(a.unicodeScalars.allSatisfy(allowed.contains))
        for forbidden in ["+", "/", "=", " "] {
            #expect(!a.contains(forbidden))
        }
    }
}
