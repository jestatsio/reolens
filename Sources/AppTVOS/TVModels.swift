import Foundation
import Observation
import OSLog
import ReolinkAPI

private let log = Logger(subsystem: "com.reolens.tvOS", category: "list")

/// 0.7.0 — slim, decode-only mirror of the `CameraEntry` fields the Apple
/// TV viewer needs. Re-declared here (rather than depending on
/// `AppShared`) so the tvOS library stays thin — same precedent as
/// `AppWatch`. Codable ignores the many other `cameras.json` fields.
///
/// **Contract:** the `CodingKeys` below MUST match `CameraEntry`'s custom
/// encoder in `Sources/AppShared/CameraStore.swift`. A drift silently
/// drops cameras on tvOS. (Follow-up: factor `CameraEntry` into
/// `ReolinkAPI` to share one source of truth — see AppTVOS/README.md.)
public struct TVCameraEntry: Decodable, Identifiable, Sendable, Hashable {
    public let id: UUID
    public let displayName: String
    public let host: String
    public let port: Int
    public let username: String
    public let useHTTPS: Bool
    public let preferredCodec: VideoCodec
    public let channelOrder: [Int]

    enum CodingKeys: String, CodingKey {
        case id, displayName, host, port, username, useHTTPS, preferredCodec, channelOrder
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.host = try c.decode(String.self, forKey: .host)
        self.port = try c.decode(Int.self, forKey: .port)
        self.username = try c.decode(String.self, forKey: .username)
        self.useHTTPS = (try? c.decode(Bool.self, forKey: .useHTTPS)) ?? false
        self.preferredCodec = (try? c.decode(VideoCodec.self, forKey: .preferredCodec)) ?? .h264
        self.channelOrder = (try? c.decode([Int].self, forKey: .channelOrder)) ?? []
    }

    /// Primary channel to show on the big screen (first in the user's
    /// order, else channel 0).
    public var primaryChannel: Int { channelOrder.first ?? 0 }
}

/// Reads the shared `cameras.json` from the iCloud Drive ubiquity
/// container — the same file the Mac/iOS apps publish via
/// `ICloudCameraStorage`. Read-only on tvOS; best-effort (a missing or
/// not-yet-downloaded file surfaces as an empty list, and the UI shows a
/// "open Reolens on your iPhone/Mac" hint).
@MainActor
@Observable
public final class TVCameraListStore {
    public private(set) var cameras: [TVCameraEntry] = []
    public private(set) var didLoad = false

    private static let containerID = "iCloud.com.reolens.Reolens"

    public init() {}

    public func load() async {
        let cameras = await Self.readFromICloud()
        self.cameras = cameras
        self.didLoad = true
        log.info("tvOS camera list loaded: \(cameras.count, privacy: .public) camera(s)")
    }

    /// Resolves the ubiquity container off the main actor (the call can
    /// block) and decodes `Documents/cameras.json`.
    private static func readFromICloud() async -> [TVCameraEntry] {
        let id = containerID
        let url: URL? = await Task.detached {
            FileManager.default.url(forUbiquityContainerIdentifier: id)?
                .appendingPathComponent("Documents/cameras.json")
        }.value
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([TVCameraEntry].self, from: data)) ?? []
    }
}
