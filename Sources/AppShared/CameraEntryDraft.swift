import Foundation
import ReolinkAPI

/// The raw add-camera form fields plus a pure validator, shared by the macOS
/// (`AddCameraSheet`) and iOS (`AddCameraView`) add flows so the rules and the
/// error wording are defined exactly once (AGENTS.md §1 parity, §6 shared
/// logic). Replaces the old "build a `CameraEntry` from raw text and append
/// blindly" path.
///
/// All field-error strings are static — the user's typed value is never echoed
/// back into a message (AGENTS.md §3). The validator explicitly rejects
/// scheme-prefixed and `user:pass@host` input so credentials can't end up
/// embedded in the stored host.
public struct CameraEntryDraft: Sendable {
    public var displayName: String
    public var host: String
    /// Raw port text from the field; parsed and range-checked here.
    public var port: String
    public var username: String
    public var useHTTPS: Bool
    public var preferredCodec: VideoCodec
    /// The control plane discovery detected for this device, when it came from
    /// the auto-detect picker. Carried into the stored `CameraEntry` so a
    /// web-API-off (`.baichuan`) camera connects straight over port 9000 on its
    /// very first connect instead of burning the HTTP→HTTPS refusal budget
    /// first (GitHub #76). `nil` for manual entry (unknown until first connect).
    public var controlTransport: ControlTransport?

    public init(
        displayName: String,
        host: String,
        port: String,
        username: String,
        useHTTPS: Bool = false,
        preferredCodec: VideoCodec = .h264,
        controlTransport: ControlTransport? = nil
    ) {
        self.displayName = displayName
        self.host = host
        self.port = port
        self.username = username
        self.useHTTPS = useHTTPS
        self.preferredCodec = preferredCodec
        self.controlTransport = controlTransport
    }

    public enum Field: Hashable, Sendable { case host, port, username }

    public enum Result: Sendable {
        case valid(CameraEntry)
        case invalid([Field: String])
    }

    /// Validate against the cameras already in the store (for duplicate
    /// detection). Returns a ready-to-store `CameraEntry` with trimmed fields,
    /// or per-field error messages.
    public func validate(existing: [CameraEntry]) -> Result {
        var errors: [Field: String] = [:]

        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedHost.isEmpty {
            errors[.host] = "Enter the camera's IP address or hostname."
        } else if trimmedHost.contains("://") {
            errors[.host] = "Enter just the address — no http:// or https:// prefix."
        } else if trimmedHost.contains(" ") {
            errors[.host] = "The address can't contain spaces."
        } else if trimmedHost.contains("@") {
            errors[.host] = "Enter just the address — put the username and password in their own fields."
        }

        let trimmedPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
        let portValue = Int(trimmedPort)
        if portValue == nil || !(1...65535).contains(portValue!) {
            errors[.port] = "Port must be a number from 1 to 65535."
        }

        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedUser.isEmpty {
            errors[.username] = "Enter the camera's username."
        }

        // Duplicate check only when the address fields are otherwise valid.
        if errors[.host] == nil, errors[.username] == nil, let portValue {
            let isDuplicate = existing.contains { entry in
                entry.host.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(trimmedHost) == .orderedSame
                    && entry.port == portValue
                    && entry.username.caseInsensitiveCompare(trimmedUser) == .orderedSame
            }
            if isDuplicate {
                errors[.host] = "A camera at this address is already added."
            }
        }

        guard errors.isEmpty, let portValue else { return .invalid(errors) }

        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = CameraEntry(
            displayName: trimmedName.isEmpty ? trimmedHost : trimmedName,
            host: trimmedHost,
            port: portValue,
            username: trimmedUser,
            useHTTPS: useHTTPS,
            preferredCodec: preferredCodec,
            controlTransport: controlTransport
        )
        return .valid(entry)
    }
}
