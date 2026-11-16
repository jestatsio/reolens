import Foundation

/// The class of a Reolink device exposed by the API.
///
/// Clean replacement for the firmware-shaped `DeviceInfo.type` string
/// (`"camera"` / `"nvr"` / `"hub"`) plus the `isNVR` / `isHomeHub` heuristics.
public enum DeviceKind: String, Sendable, Codable, CaseIterable, Hashable {
    case camera
    case nvr
    case hub
}

/// A detection category, normalized away from Reolink's wire vocabulary.
///
/// The Reolink wire uses `people` / `dog_cat`; the contract uses the clearer
/// `person` / `pet`. Mapping happens once, in the adapter — consumers only
/// ever see these names.
public enum DetectionKind: String, Sendable, Codable, CaseIterable, Hashable {
    case motion
    case person
    case vehicle
    case pet
    case face
    case package
    case visitor
    case other
}

/// Which encoded stream a media request targets.
///
/// `main` is full-resolution; `sub` is the lower-bitrate stream the app
/// defaults to in grids (AGENTS.md §10). Mapped to Reolink `StreamKind`
/// in the adapter.
public enum StreamQuality: String, Sendable, Codable, CaseIterable, Hashable {
    case main
    case sub
}

/// A camera session's connection state, as reported by diagnostics.
///
/// 0.10.0 cleanup: was a bare `String` on ``CameraDiagnostics``. Raw values
/// are unchanged, so the `/v1` wire shape is identical; only the Swift type
/// tightened. Named distinctly from AppShared's internal `ConnectionStatus`
/// (which carries an associated error reason and never leaves the app).
public enum CameraConnectionStatus: String, Sendable, Codable, CaseIterable, Hashable {
    case connected
    case connecting
    case disconnected
    case error
}

/// The control plane a camera session connected over, as reported by
/// diagnostics. Mirrors AppShared's persisted `ControlTransport` raw values
/// (`http` / `https` / `baichuan`) without coupling the contract to the
/// app's synced-schema type.
public enum CameraControlTransport: String, Sendable, Codable, CaseIterable, Hashable {
    case http
    case https
    case baichuan
}
