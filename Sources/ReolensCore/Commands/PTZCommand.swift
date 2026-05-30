import Foundation

/// A pan/tilt/zoom instruction.
///
/// Modeled as a flat value so it maps cleanly onto the HTTP body
/// `{ "op": "left", "speed": 32 }` and onto Reolink's `PtzOp` in the adapter.
/// `speed` and `presetID` are only meaningful for some ops (see ``PTZOp``).
public struct PTZCommand: Sendable, Codable, Hashable {
    /// The operation to perform.
    public let op: PTZOp
    /// Movement speed (roughly 1–63); ignored by `stop` and preset ops. Defaults
    /// applied by the adapter when nil.
    public let speed: Int?
    /// Preset slot, required for ``PTZOp/toPreset``; ignored otherwise.
    public let presetID: Int?

    public init(op: PTZOp, speed: Int? = nil, presetID: Int? = nil) {
        self.op = op
        self.speed = speed
        self.presetID = presetID
    }
}

/// The set of PTZ operations the API exposes. Names are chosen for clarity at
/// the point of use; the adapter maps each to the corresponding Reolink `PtzOp`
/// (e.g. ``focusNear`` → `focusIn`, ``autoScan`` → `auto`, ``toPreset`` → `toPos`).
public enum PTZOp: String, Sendable, Codable, CaseIterable, Hashable {
    case left
    case right
    case up
    case down
    case leftUp
    case leftDown
    case rightUp
    case rightDown
    case zoomIn
    case zoomOut
    case focusNear
    case focusFar
    case stop
    case autoScan
    case toPreset
    case startPatrol
    case stopPatrol
}
