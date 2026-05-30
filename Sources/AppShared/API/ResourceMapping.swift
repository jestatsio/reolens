import Foundation
import ReolinkAPI
import ReolensCore

/// Pure mappers from Reolink wire models to clean `ReolensCore` resources.
///
/// Kept as static functions over value types so the mapping logic is unit-
/// testable without a `CameraStore`, a session, or any network. This is the
/// single place Reolink's vocabulary (`people` / `dog_cat`, trigger bitfields,
/// `PtzOp` raw strings) is translated into the public contract.
enum ResourceMapping {

    /// Device class from `GetDevInfo` (falls back to `.camera` when unknown).
    static func deviceKind(_ info: DeviceInfo?) -> DeviceKind {
        guard let info else { return .camera }
        if info.isHomeHub { return .hub }
        if info.isNVR { return .nvr }
        return .camera
    }

    /// Map a raw Reolink AI tag (from a Baichuan event) to a contract category.
    static func detection(fromReolinkTag tag: String) -> DetectionKind {
        switch tag.lowercased() {
        case "people", "person": return .person
        case "vehicle": return .vehicle
        case "dog_cat", "pet", "animal": return .pet
        case "face": return .face
        case "package": return .package
        case "visitor": return .visitor
        default: return .other
        }
    }

    /// Map a decoded `SearchFile` trigger category to a contract category.
    static func detection(_ type: DetectionType) -> DetectionKind {
        switch type {
        case .motion: return .motion
        case .person: return .person
        case .vehicle: return .vehicle
        case .pet: return .pet
        case .face: return .face
        case .packageDelivery: return .package
        case .visitor: return .visitor
        case .other: return .other
        }
    }

    /// Map a contract PTZ operation to the Reolink `PtzOp`.
    static func ptzOp(_ op: PTZOp) -> PtzOp {
        switch op {
        case .left: return .left
        case .right: return .right
        case .up: return .up
        case .down: return .down
        case .leftUp: return .leftUp
        case .leftDown: return .leftDown
        case .rightUp: return .rightUp
        case .rightDown: return .rightDown
        case .zoomIn: return .zoomIn
        case .zoomOut: return .zoomOut
        case .focusNear: return .focusIn
        case .focusFar: return .focusOut
        case .stop: return .stop
        case .autoScan: return .auto
        case .toPreset: return .toPos
        case .startPatrol: return .startPatrol
        case .stopPatrol: return .stopPatrol
        }
    }

    /// Map a `SearchFile` to a `RecordingResource`. Returns nil when the file's
    /// start/end timestamps can't be resolved (the resource requires real dates).
    static func recording(_ file: SearchFile) -> RecordingResource? {
        guard let start = file.startDate, let end = file.endDate else { return nil }
        return RecordingResource(
            id: file.name,
            start: start,
            end: end,
            triggers: file.triggers.map(detection),
            sizeBytes: file.size.map(Int64.init),
            width: file.width,
            height: file.height
        )
    }

    /// The AI categories a channel supports, from a `GetAiState` response.
    static func aiSupport(_ state: AIStateValue) -> [DetectionKind] {
        var result: [DetectionKind] = []
        if state.people?.isSupported == true { result.append(.person) }
        if state.vehicle?.isSupported == true { result.append(.vehicle) }
        if state.dog_cat?.isSupported == true { result.append(.pet) }
        if state.face?.isSupported == true { result.append(.face) }
        if state.package?.isSupported == true { result.append(.package) }
        if state.visitor?.isSupported == true { result.append(.visitor) }
        if state.other?.isSupported == true { result.append(.other) }
        return result
    }
}
