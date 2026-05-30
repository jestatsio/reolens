import Foundation
import Testing
import ReolensCore

@Suite("EventFilter matching")
struct EventFilterTests {
    static let t = Date(timeIntervalSince1970: 1_700_000_000)

    private func event(
        camera: CameraID = "CAM-1",
        channel: Int = 0,
        kind: EventKind = .ai,
        detection: DetectionKind? = .person
    ) -> EventResource {
        EventResource(id: "E", cameraID: camera, channel: channel, kind: kind, detection: detection, timestamp: Self.t)
    }

    @Test("An empty filter matches everything")
    func emptyMatchesAll() {
        #expect(EventFilter.all.matches(event()))
        #expect(EventFilter.all.matches(event(kind: .motionStart, detection: nil)))
    }

    @Test("Camera filter excludes other cameras")
    func cameraFilter() {
        let f = EventFilter(cameraID: "CAM-1")
        #expect(f.matches(event(camera: "CAM-1")))
        #expect(!f.matches(event(camera: "CAM-2")))
    }

    @Test("Channel filter excludes other channels")
    func channelFilter() {
        let f = EventFilter(channel: 3)
        #expect(f.matches(event(channel: 3)))
        #expect(!f.matches(event(channel: 0)))
    }

    @Test("Detection allow-list excludes other detections and motion edges")
    func detectionFilter() {
        let f = EventFilter(detections: [.person, .vehicle])
        #expect(f.matches(event(detection: .person)))
        #expect(!f.matches(event(detection: .pet)))
        // A motion edge (no detection) is filtered out when a detection
        // allow-list is present.
        #expect(!f.matches(event(kind: .motionStart, detection: nil)))
    }
}
