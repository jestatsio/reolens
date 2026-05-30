import Foundation
import Testing
import ReolinkAPI
import ReolensCore
@testable import AppShared

/// Phase 2 — pure mapping + event-bus tests for the in-process `CameraAPI`
/// adapter. No network, no real cameras (AGENTS.md §12). The HTTP-facade
/// integration is covered separately against a fake `CameraAPI` (Phase 3).
@Suite("LiveCameraAPI mapping")
struct ResourceMappingTests {

    @Test("Reolink AI tags map to the normalized vocabulary")
    func detectionFromTag() {
        #expect(ResourceMapping.detection(fromReolinkTag: "people") == .person)
        #expect(ResourceMapping.detection(fromReolinkTag: "dog_cat") == .pet)
        #expect(ResourceMapping.detection(fromReolinkTag: "vehicle") == .vehicle)
        #expect(ResourceMapping.detection(fromReolinkTag: "face") == .face)
        #expect(ResourceMapping.detection(fromReolinkTag: "something_new") == .other)
    }

    @Test("Trigger categories map, including packageDelivery → package")
    func detectionFromType() {
        #expect(ResourceMapping.detection(.packageDelivery) == .package)
        #expect(ResourceMapping.detection(.pet) == .pet)
        #expect(ResourceMapping.detection(.motion) == .motion)
        // Every Reolink trigger type has a contract mapping.
        for type in DetectionType.allCases {
            _ = ResourceMapping.detection(type)
        }
    }

    @Test("Every contract PTZ op maps to a Reolink PtzOp")
    func ptzMapping() {
        #expect(ResourceMapping.ptzOp(.focusNear) == .focusIn)
        #expect(ResourceMapping.ptzOp(.focusFar) == .focusOut)
        #expect(ResourceMapping.ptzOp(.autoScan) == .auto)
        #expect(ResourceMapping.ptzOp(.toPreset) == .toPos)
        #expect(ResourceMapping.ptzOp(.left) == .left)
        for op in PTZOp.allCases {
            _ = ResourceMapping.ptzOp(op)   // total — no crash
        }
    }

    @Test("AI support flags decode to the supported categories")
    func aiSupportMapping() throws {
        let json = Data(#"""
        {"channel":0,"people":{"support":1,"alarm_state":0},
         "vehicle":{"support":0},"dog_cat":{"support":1},"face":{"support":1}}
        """#.utf8)
        let state = try JSONDecoder().decode(AIStateValue.self, from: json)
        let supported = ResourceMapping.aiSupport(state)
        #expect(supported.contains(.person))
        #expect(supported.contains(.pet))
        #expect(supported.contains(.face))
        #expect(!supported.contains(.vehicle))
    }

    @Test("Device kind resolves from GetDevInfo shape")
    func deviceKind() throws {
        func info(_ json: String) throws -> DeviceInfo {
            try JSONDecoder().decode(DeviceInfo.self, from: Data(json.utf8))
        }
        #expect(ResourceMapping.deviceKind(nil) == .camera)
        #expect(try ResourceMapping.deviceKind(info(#"{"type":"Hub"}"#)) == .hub)
        #expect(try ResourceMapping.deviceKind(info(#"{"type":"nvr","channelNum":8}"#)) == .nvr)
        #expect(try ResourceMapping.deviceKind(info(#"{"channelNum":8}"#)) == .nvr)
        #expect(try ResourceMapping.deviceKind(info(#"{"type":"camera","channelNum":1}"#)) == .camera)
    }
}

@Suite("LiveCameraAPI helpers")
struct LiveCameraAPIHelperTests {

    @Test("Recording cursor round-trips and tolerates junk")
    func cursorRoundTrip() {
        for offset in [0, 1, 42, 1000] {
            let cursor = LiveCameraAPI.encodeCursor(offset)
            #expect(LiveCameraAPI.decodeCursor(cursor) == offset)
        }
        #expect(LiveCameraAPI.decodeCursor(nil) == 0)
        #expect(LiveCameraAPI.decodeCursor("not-base64!!") == 0)
    }

    @Test("Bus event maps to an EventResource with the right kind + detection")
    func eventMapping() {
        let cam = UUID()
        let t = Date(timeIntervalSince1970: 1_700_000_000)

        let ai = LiveCameraAPI.eventResource(
            .init(cameraID: cam, channel: 2, kind: .ai("people"), timestamp: t)
        )
        #expect(ai.cameraID == cam.uuidString)
        #expect(ai.channel == 2)
        #expect(ai.kind == .ai)
        #expect(ai.detection == .person)
        #expect(ai.timestamp == t)

        let motion = LiveCameraAPI.eventResource(
            .init(cameraID: cam, channel: 0, kind: .motionStart, timestamp: t)
        )
        #expect(motion.kind == .motionStart)
        #expect(motion.detection == nil)
    }
}

@Suite("MotionEventStream")
struct MotionEventStreamTests {

    @Test("Subscribe then publish delivers the event")
    func deliversEvents() async {
        let bus = MotionEventStream()   // fresh instance for isolation
        let stream = await bus.subscribe()
        var iterator = stream.makeAsyncIterator()

        let cam = UUID()
        await bus.publish(.init(cameraID: cam, channel: 3, kind: .ai("vehicle"), timestamp: Date(timeIntervalSince1970: 1)))

        let received = await iterator.next()
        #expect(received?.cameraID == cam)
        #expect(received?.channel == 3)
        #expect(received?.kind == .ai("vehicle"))
    }

    @Test("A finished subscription is unregistered")
    func unsubscribeOnTerminate() async {
        let bus = MotionEventStream()
        do {
            let stream = await bus.subscribe()
            #expect(await bus.subscriberCount == 1)
            _ = stream   // drop at end of scope → onTermination fires
        }
        // Allow the termination handler's unsubscribe task to run.
        await Task.yield()
        // Best-effort: the count returns to zero once the stream is released.
        var count = await bus.subscriberCount
        var spins = 0
        while count != 0 && spins < 100 {
            await Task.yield()
            count = await bus.subscriberCount
            spins += 1
        }
        #expect(count == 0)
    }
}
