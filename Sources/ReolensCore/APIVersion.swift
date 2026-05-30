import Foundation

/// The public API contract version.
///
/// `ReolensCore` is the single source of truth for the Reolens API surface:
/// a clean, **Reolink-agnostic** set of resource types plus the ``CameraAPI``
/// protocol. The in-process implementation (`LiveCameraAPI` in `AppShared`)
/// and the HTTP facade (`ReolensServer`) both speak this contract, so a wire
/// quirk in a Reolink firmware never leaks into anything a consumer sees.
///
/// Versioning rules (see `docs/api/README.md`):
/// - Additive, backward-compatible changes stay within `v1`.
/// - A breaking change mints a new major (`v2`) served under a new path prefix.
public enum APIVersion {
    /// The current contract major, e.g. `"v1"`.
    public static let current = "v1"

    /// The URL path prefix the HTTP facade mounts the contract under, e.g. `"/v1"`.
    public static let pathPrefix = "/" + current
}

/// Opaque identifier for a camera device. Mirrors `CameraEntry.id.uuidString`
/// but is treated as an opaque string by API consumers.
public typealias CameraID = String

/// Opaque identifier for a single recording. The in-process implementation
/// encodes whatever it needs to locate the clip (camera, channel, file name)
/// into this string; consumers must treat it as opaque.
public typealias RecordingID = String
