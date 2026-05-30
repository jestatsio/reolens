import Foundation

/// The Reolens API — the single, Reolink-agnostic contract that both the app's
/// own surfaces and external consumers are built on.
///
/// One implementation, `LiveCameraAPI` (in `AppShared`), adapts this onto the
/// existing `CameraStore` / `CameraSession` stack. The HTTP facade
/// (`ReolensServer`) is generic over `any CameraAPI`, so it can be exercised in
/// tests against an in-memory fake with no cameras and no sockets.
///
/// Conformers must be `Sendable` and safe to call from any isolation; the live
/// implementation hops to the `@MainActor` store internally.
public protocol CameraAPI: Sendable {

    // MARK: Devices & channels

    /// All configured cameras.
    func cameras() async throws -> [CameraResource]

    /// A single camera by id. Throws ``APIError/cameraNotFound(_:)`` if unknown.
    func camera(_ id: CameraID) async throws -> CameraResource

    /// The channels on a camera.
    func channels(_ id: CameraID) async throws -> [ChannelResource]

    // MARK: Media

    /// A current still image for a channel.
    func snapshot(_ id: CameraID, channel: Int) async throws -> ImagePayload

    /// References for viewing a channel's live video (see ``StreamRef``).
    func streamRef(_ id: CameraID, channel: Int, quality: StreamQuality) async throws -> StreamRef

    // MARK: Control

    /// Issue a pan/tilt/zoom command. Returns once the command is dispatched;
    /// it does not wait for the camera to finish moving.
    func ptz(_ id: CameraID, channel: Int, _ command: PTZCommand) async throws

    // MARK: Recordings

    /// Search recordings on a channel within the query's time window.
    func recordings(_ id: CameraID, channel: Int, _ query: RecordingQuery) async throws -> RecordingPage

    /// Resolve a downloadable reference for a recording id.
    func recordingDownload(_ id: CameraID, _ recording: RecordingID) async throws -> DownloadRef

    // MARK: Settings

    /// Read the mutable settings for a channel.
    func settings(_ id: CameraID, channel: Int) async throws -> ChannelSettings

    /// Apply a partial settings update and return the resulting settings.
    func updateSettings(_ id: CameraID, channel: Int, _ patch: ChannelSettingsPatch) async throws -> ChannelSettings

    // MARK: Live events & system

    /// A live stream of motion / AI events matching `filter`. The stream stays
    /// open until the consumer stops iterating (or the task is cancelled).
    func events(_ filter: EventFilter) -> AsyncStream<EventResource>

    /// Liveness / summary for this instance. Safe to call unauthenticated.
    func health() async throws -> SystemHealth
}
