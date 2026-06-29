import Foundation

/// How Reolens reaches a camera's *control plane* — the channel it uses for
/// device info, PTZ, snapshots, and recording search (live video always rides
/// RTSP:554 regardless).
///
/// Newer Reolink firmware (3.1.0.x, e.g. the CX410) ships with the HTTP/HTTPS
/// CGI API disabled by default and only the Baichuan port (9000) open, so the
/// transport a camera answers on is no longer a given — discovery probes for
/// each and records which one actually responded. GitHub #76.
public enum ControlTransport: String, Codable, Sendable, Hashable, CaseIterable {
    /// Plain HTTP CGI on :80.
    case http
    /// TLS CGI on :443 (self-signed; TOFU-pinned once authenticated).
    case https
    /// Reolink's binary Baichuan protocol on TCP :9000 — the only control
    /// path on cameras that ship the web API off.
    case baichuan
}
