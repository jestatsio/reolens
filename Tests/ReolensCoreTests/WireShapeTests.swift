import Foundation
import Testing
import ReolensCore

/// Assertions that pin the *public JSON shape* — key names, enum raw values,
/// and the envelope/error contract — so an accidental rename is caught here
/// rather than by a downstream consumer.
@Suite("ReolensCore wire shape")
struct WireShapeTests {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private func object(_ value: some Encodable) throws -> [String: Any] {
        let data = try Self.encoder.encode(value)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("CameraResource exposes stable keys and a lowercase kind")
    func cameraKeys() throws {
        let obj = try object(CameraResource(
            id: "CAM-1", displayName: "Front Door", kind: .camera, channelCount: 1, online: true
        ))
        for key in ["id", "displayName", "kind", "channelCount", "online"] {
            #expect(obj[key] != nil, "missing key \(key)")
        }
        #expect(obj["kind"] as? String == "camera")
    }

    @Test("Detection categories use the normalized vocabulary")
    func detectionRawValues() {
        #expect(DetectionKind.person.rawValue == "person")
        #expect(DetectionKind.pet.rawValue == "pet")
        #expect(DetectionKind.vehicle.rawValue == "vehicle")
        // Reolink's wire `people` / `dog_cat` must NOT leak into the contract.
        #expect(!DetectionKind.allCases.map(\.rawValue).contains("people"))
        #expect(!DetectionKind.allCases.map(\.rawValue).contains("dog_cat"))
    }

    @Test("PTZ command decodes from the documented HTTP body")
    func ptzBody() throws {
        let json = Data(#"{"op":"left","speed":32}"#.utf8)
        let cmd = try JSONDecoder().decode(PTZCommand.self, from: json)
        #expect(cmd.op == .left)
        #expect(cmd.speed == 32)
        #expect(cmd.presetID == nil)
    }

    @Test("Success envelope carries data + meta and omits error")
    func successEnvelope() throws {
        let resp = APIResponse<[CameraResource]>.success(
            [CameraResource(id: "CAM-1", displayName: "A", kind: .camera, channelCount: 1, online: true)],
            meta: APIMeta(count: 1, nextCursor: nil)
        )
        let obj = try object(resp)
        #expect(obj["data"] != nil)
        #expect(obj["meta"] != nil)
        #expect(obj["error"] == nil, "nil error must be omitted, not encoded null")
    }

    @Test("Error envelope carries a stable code + status and omits data")
    func errorEnvelope() throws {
        let resp = APIResponse<[CameraResource]>(error: .cameraNotFound("CAM-X"))
        let obj = try object(resp)
        #expect(obj["data"] == nil)
        let err = try #require(obj["error"] as? [String: Any])
        #expect(err["code"] as? String == "camera_not_found")
        #expect(err["status"] as? Int == 404)
        #expect(err["message"] != nil)
    }

    @Test("APIError factories map to the right HTTP status")
    func errorStatuses() {
        #expect(APIError.badRequest().status == 400)
        #expect(APIError.unauthorized().status == 401)
        #expect(APIError.forbidden().status == 403)
        #expect(APIError.channelNotFound(channel: 2).status == 404)
        #expect(APIError.upstreamUnreachable().status == 502)
        #expect(APIError.notImplemented().status == 501)
    }

    @Test("API version prefix is /v1")
    func versionPrefix() {
        #expect(APIVersion.current == "v1")
        #expect(APIVersion.pathPrefix == "/v1")
    }
}
