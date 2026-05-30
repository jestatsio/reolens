import Foundation
import Testing
import ReolensCore

/// Encode→decode identity for every resource DTO. The DTOs are a public wire
/// format, so a round-trip regression is a breaking-change alarm.
@Suite("ReolensCore Codable round-trips")
struct CodableRoundTripTests {
    // Whole-second dates so ISO-8601 (the server's strategy) round-trips exactly.
    static let date0 = Date(timeIntervalSince1970: 1_700_000_000)
    static let date1 = Date(timeIntervalSince1970: 1_700_000_030)

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let data = try Self.encoder.encode(value)
        return try Self.decoder.decode(T.self, from: data)
    }

    @Test("CameraResource round-trips")
    func cameraResource() throws {
        let value = CameraResource(
            id: "CAM-1",
            displayName: "Front Door",
            kind: .hub,
            model: "Home Hub Pro",
            firmwareVersion: "3.1.0",
            channelCount: 4,
            online: true,
            host: "192.168.1.50"
        )
        #expect(try roundTrip(value) == value)
    }

    @Test("ChannelResource (with battery + capabilities) round-trips")
    func channelResource() throws {
        let value = ChannelResource(
            id: 2,
            name: "Driveway",
            online: true,
            isDualLens: true,
            isBatteryPowered: true,
            battery: BatteryInfo(percent: 73, charging: false, pluggedIn: false),
            capabilities: ChannelCapabilities(ptz: true, talk: true, ai: [.person, .vehicle, .pet])
        )
        #expect(try roundTrip(value) == value)
    }

    @Test("RecordingResource round-trips and computes duration")
    func recordingResource() throws {
        let value = RecordingResource(
            id: "REC-1",
            start: Self.date0,
            end: Self.date1,
            triggers: [.motion, .person],
            sizeBytes: 1_048_576,
            width: 2560,
            height: 1440
        )
        #expect(value.durationSeconds == 30)
        #expect(try roundTrip(value) == value)
    }

    @Test("RecordingPage round-trips")
    func recordingPage() throws {
        let page = RecordingPage(
            items: [RecordingResource(id: "REC-1", start: Self.date0, end: Self.date1)],
            nextCursor: "eyJvIjoxMH0"
        )
        #expect(try roundTrip(page) == page)
    }

    @Test("EventResource round-trips")
    func eventResource() throws {
        let value = EventResource(
            id: "EVT-1",
            cameraID: "CAM-1",
            channel: 0,
            kind: .ai,
            detection: .person,
            timestamp: Self.date0
        )
        #expect(try roundTrip(value) == value)
    }

    @Test("StreamRef round-trips")
    func streamRef() throws {
        let value = StreamRef(
            quality: .sub,
            codec: "h265",
            mjpeg: URL(string: "https://reolens.local/v1/cameras/CAM-1/channels/0/mjpeg"),
            rtsp: nil,
            hls: nil
        )
        #expect(try roundTrip(value) == value)
    }

    @Test("ChannelSettings round-trips")
    func channelSettings() throws {
        let value = ChannelSettings(
            name: "Garage",
            osd: OSDSettings(showName: true, showDate: false),
            notificationsEnabled: true
        )
        #expect(try roundTrip(value) == value)
    }

    @Test("SystemHealth round-trips")
    func systemHealth() throws {
        let value = SystemHealth(appVersion: "0.8.4", cameraCount: 5, onlineCount: 4, hubRunning: true)
        #expect(try roundTrip(value) == value)
    }

    @Test("PTZCommand round-trips")
    func ptzCommand() throws {
        for op in PTZOp.allCases {
            let value = PTZCommand(op: op, speed: 32, presetID: op == .toPreset ? 3 : nil)
            #expect(try roundTrip(value) == value)
        }
    }

    @Test("RecordingQuery round-trips")
    func recordingQuery() throws {
        let value = RecordingQuery(from: Self.date0, to: Self.date1, types: [.person], cursor: "c1", limit: 50)
        #expect(try roundTrip(value) == value)
    }
}
