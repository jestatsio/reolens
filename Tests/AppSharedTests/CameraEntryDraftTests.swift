import Testing
import Foundation
@testable import AppShared

/// 0.9.0 C — the add-camera form used to build a `CameraEntry` from raw text
/// and append it blindly. `CameraEntryDraft` validates first, shared by both
/// platform views. These pin the rules (incl. AGENTS.md §3: reject embedded
/// credentials) without any UI.
@Suite("CameraEntryDraft validation")
struct CameraEntryDraftTests {

    private func draft(
        host: String = "192.168.1.50",
        port: String = "80",
        username: String = "admin",
        name: String = "Front Door"
    ) -> CameraEntryDraft {
        CameraEntryDraft(displayName: name, host: host, port: port, username: username)
    }

    private func errors(_ result: CameraEntryDraft.Result) -> [CameraEntryDraft.Field: String]? {
        if case .invalid(let e) = result { return e }
        return nil
    }

    @Test("a well-formed draft validates and trims its fields")
    func happyPath() {
        let result = draft(host: "  192.168.1.7 ", port: "443", username: " admin ", name: "  Yard ")
            .validate(existing: [])
        guard case .valid(let entry) = result else { Issue.record("expected valid"); return }
        #expect(entry.host == "192.168.1.7")
        #expect(entry.port == 443)
        #expect(entry.username == "admin")
        #expect(entry.displayName == "Yard")
    }

    @Test("an empty display name falls back to the host")
    func emptyNameFallsBackToHost() {
        let result = draft(name: "   ").validate(existing: [])
        guard case .valid(let entry) = result else { Issue.record("expected valid"); return }
        #expect(entry.displayName == "192.168.1.50")
    }

    @Test("invalid hosts are rejected", arguments: [
        "", "   ", "http://192.168.1.5", "https://cam.local", "192.168 1 5", "admin:pw@192.168.1.5",
    ])
    func invalidHosts(host: String) {
        let result = draft(host: host).validate(existing: [])
        #expect(errors(result)?[.host] != nil)
    }

    @Test("invalid ports are rejected", arguments: ["0", "65536", "70000", "abc", "", "-1"])
    func invalidPorts(port: String) {
        let result = draft(port: port).validate(existing: [])
        #expect(errors(result)?[.port] != nil)
    }

    @Test("an empty username is rejected")
    func emptyUsername() {
        let result = draft(username: "   ").validate(existing: [])
        #expect(errors(result)?[.username] != nil)
    }

    @Test("a duplicate host+port+username is flagged on the host field")
    func duplicateRejected() {
        let existing = [CameraEntry(displayName: "Existing", host: "192.168.1.50", port: 80, username: "admin")]
        let result = draft(host: "192.168.1.50", port: "80", username: "admin").validate(existing: existing)
        let hostError = errors(result)?[.host]
        #expect(hostError?.contains("already added") == true)
    }

    @Test("a different username at the same address is not a duplicate")
    func differentUserIsNotDuplicate() {
        let existing = [CameraEntry(displayName: "Existing", host: "192.168.1.50", port: 80, username: "admin")]
        let result = draft(host: "192.168.1.50", port: "80", username: "viewer").validate(existing: existing)
        if case .valid = result {} else { Issue.record("expected valid for a different username") }
    }

    @Test("field error strings never echo the typed host or credentials (§3)")
    func messagesAreStaticAndCredentialFree() {
        let result = draft(host: "admin:secret@10.9.9.9").validate(existing: [])
        let message = errors(result)?[.host] ?? ""
        #expect(!message.contains("10.9.9.9"))
        #expect(!message.contains("secret"))
        #expect(!message.contains("@"))
    }
}
