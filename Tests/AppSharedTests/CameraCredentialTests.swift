import Testing
import Foundation
import CloudKit
@testable import AppShared

/// 0.7.0 — `CameraCredential` carries an encrypted camera password to
/// tvOS via the user's private CloudKit DB. Tests pin the record
/// round-trip (including the encrypted field) and the decode guards,
/// against a locally-built `CKRecord` (no CloudKit account / network).
@Suite("CameraCredential")
struct CameraCredentialTests {

    private let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    @Test("Password round-trips through the encrypted field")
    func roundTrip() throws {
        let cred = CameraCredential(cameraID: id, password: "s3cr3t-pass")
        let record = cred.toRecord()

        // The password must live in encryptedValues, never as a plaintext
        // top-level field.
        #expect(record[CameraCredential.RecordKey.password] == nil)
        #expect(record.encryptedValues[CameraCredential.RecordKey.password] as? String == "s3cr3t-pass")

        let decoded = try #require(CameraCredential.decode(record: record))
        #expect(decoded.cameraID == id)
        #expect(decoded.password == "s3cr3t-pass")
    }

    @Test("Record name is stable per camera (replace-in-place)")
    func stableRecordName() {
        let record = CameraCredential(cameraID: id, password: "x").toRecord()
        #expect(record.recordID.recordName == "cred-\(id.uuidString)")
        #expect(CameraCredential.recordName(for: id) == "cred-\(id.uuidString)")
    }

    @Test("Wrong record type decodes to nil")
    func wrongType() {
        #expect(CameraCredential.decode(record: CKRecord(recordType: "MotionEvent")) == nil)
    }

    @Test("Missing password decodes to nil")
    func missingPassword() {
        let record = CKRecord(recordType: CameraCredential.recordType)
        record[CameraCredential.RecordKey.cameraID] = id.uuidString as NSString
        #expect(CameraCredential.decode(record: record) == nil)
    }
}
