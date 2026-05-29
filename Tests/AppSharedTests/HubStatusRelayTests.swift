import Testing
import Foundation
import CloudKit
@testable import AppShared

/// 0.7.0 — `HubStatus` is the CloudKit heartbeat behind the Hub-offline
/// banner. These tests pin its record round-trip and decode guards
/// against a locally-built `CKRecord` (no CloudKit account / network):
///
/// - every field survives toRecord → decode
/// - the relay flag round-trips both ways
/// - a wrong record type / missing required field decodes to nil
/// - `serverModifiedAt` is nil for a locally-built record (it's only set
///   by the CloudKit server on save)
@Suite("HubStatusRelay")
struct HubStatusRelayTests {

    private func sample(relayOn: Bool = true) -> HubStatus {
        HubStatus(
            hubDeviceID: "device-abc",
            hubDeviceName: "Mac mini",
            lastSeen: Date(timeIntervalSince1970: 1_700_000_000),
            appVersion: "0.7.0",
            relayPublisherEnabled: relayOn
        )
    }

    @Test("Every field survives toRecord → decode")
    func roundTrip() throws {
        let original = sample()
        let decoded = try #require(HubStatus.decode(record: original.toRecord()))

        #expect(decoded.hubDeviceID == original.hubDeviceID)
        #expect(decoded.hubDeviceName == original.hubDeviceName)
        #expect(decoded.lastSeen == original.lastSeen)
        #expect(decoded.appVersion == "0.7.0")
        #expect(decoded.relayPublisherEnabled)
        // modificationDate is server-assigned; a locally-built record
        // has none, so the staleness math must not depend on it here.
        #expect(decoded.serverModifiedAt == nil)
    }

    @Test("The record name is the stable hub device ID (replace-in-place)")
    func recordNameIsDeviceID() {
        #expect(sample().toRecord().recordID.recordName == "device-abc")
    }

    @Test("relayPublisherEnabled round-trips both ways", arguments: [true, false])
    func relayFlagRoundTrips(on: Bool) throws {
        let decoded = try #require(HubStatus.decode(record: sample(relayOn: on).toRecord()))
        #expect(decoded.relayPublisherEnabled == on)
    }

    @Test("appVersion is optional and decodes to nil when absent")
    func appVersionOptional() throws {
        let noVersion = HubStatus(
            hubDeviceID: "d", hubDeviceName: "Mac", lastSeen: Date(),
            appVersion: nil, relayPublisherEnabled: true
        )
        let decoded = try #require(HubStatus.decode(record: noVersion.toRecord()))
        #expect(decoded.appVersion == nil)
    }

    @Test("Wrong record type decodes to nil")
    func wrongRecordType() {
        let record = CKRecord(recordType: "SomethingElse")
        #expect(HubStatus.decode(record: record) == nil)
    }

    @Test("Missing a required field decodes to nil")
    func missingFieldFails() {
        let record = CKRecord(recordType: HubStatus.recordType)
        record[HubStatus.RecordKey.hubDeviceID] = "d" as NSString
        // No hubDeviceName / lastSeen.
        #expect(HubStatus.decode(record: record) == nil)
    }
}
