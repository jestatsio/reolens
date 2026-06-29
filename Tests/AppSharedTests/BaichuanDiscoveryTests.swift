import Testing
import Foundation
@testable import AppShared

/// GitHub #76 — newer Reolink firmware (3.1.0.x, e.g. the CX410) ships the
/// HTTP/HTTPS CGI API off and answers only on the Baichuan port (9000), so the
/// auto-detect sweep now probes 9000 alongside the web ports. These tests pin
/// the two pure pieces of that path — the magic-header wire check and the
/// probe-result precedence — so they're verifiable without a live socket.
@Suite("CameraDiscovery Baichuan port-9000 detection (#76)")
struct BaichuanDiscoveryTests {

    private func device(
        host: String = "192.168.1.50",
        port: Int = 80,
        confirmed: Bool,
        transport: ControlTransport
    ) -> DiscoveredDevice {
        DiscoveredDevice(
            host: host,
            port: port,
            displayName: host,
            kindHint: "Reolink",
            confirmedReolink: confirmed,
            controlTransport: transport
        )
    }

    // MARK: - isBaichuanReplyMagic

    @Test("the 0x0ABCDEF0 magic header (little-endian on the wire) is recognized")
    func magicHeaderRecognized() {
        let reply = Data([0xF0, 0xDE, 0xBC, 0x0A, 0x01, 0x00, 0x00, 0x00])
        #expect(CameraDiscovery.isBaichuanReplyMagic(reply))
    }

    @Test("the 0x0FEDCBA0 reversed-magic flavor is also recognized")
    func reversedMagicRecognized() {
        #expect(CameraDiscovery.isBaichuanReplyMagic(Data([0xA0, 0xCB, 0xED, 0x0F])))
    }

    @Test("a non-Baichuan service on :9000 is not mistaken for a camera")
    func unrelatedServiceRejected() {
        // e.g. an HTTP server greeting ("HTTP") or arbitrary bytes.
        #expect(!CameraDiscovery.isBaichuanReplyMagic(Data([0x48, 0x54, 0x54, 0x50])))
        #expect(!CameraDiscovery.isBaichuanReplyMagic(Data([0x00, 0x00, 0x00, 0x00])))
    }

    @Test("fewer than 4 bytes is never a confirmed Baichuan reply")
    func shortReplyRejected() {
        #expect(!CameraDiscovery.isBaichuanReplyMagic(Data([0xF0, 0xDE])))
        #expect(!CameraDiscovery.isBaichuanReplyMagic(Data()))
    }

    // MARK: - resolveDiscovery precedence

    @Test("a confirmed CGI endpoint wins over a confirmed Baichuan port")
    func confirmedWebBeatsBaichuan() {
        let web = device(port: 443, confirmed: true, transport: .https)
        let result = CameraDiscovery.resolveDiscovery(
            host: "192.168.1.50", webHits: [web], baichuanConfirmed: true
        )
        #expect(result?.controlTransport == .https)
        #expect(result?.port == 443)
    }

    @Test("a web-API-off camera (only :9000 answers) is surfaced as Baichuan")
    func baichuanOnlyDeviceSurfaced() {
        let result = CameraDiscovery.resolveDiscovery(
            host: "192.168.1.77", webHits: [], baichuanConfirmed: true
        )
        #expect(result?.controlTransport == .baichuan)
        #expect(result?.port == 9000)
        #expect(result?.confirmedReolink == true)
        #expect(result?.host == "192.168.1.77")
    }

    @Test("a confirmed Baichuan port beats an unconfirmed bare-200 web hit")
    func baichuanBeatsBareWeb() {
        let bareWeb = device(port: 80, confirmed: false, transport: .http)
        let result = CameraDiscovery.resolveDiscovery(
            host: "192.168.1.50", webHits: [bareWeb], baichuanConfirmed: true
        )
        #expect(result?.controlTransport == .baichuan)
    }

    @Test("with no Baichuan, a bare-200 web hit is still returned (legacy behavior)")
    func bareWebFallbackPreserved() {
        let bareWeb = device(port: 80, confirmed: false, transport: .http)
        let result = CameraDiscovery.resolveDiscovery(
            host: "192.168.1.50", webHits: [bareWeb], baichuanConfirmed: false
        )
        #expect(result?.controlTransport == .http)
        #expect(result?.confirmedReolink == false)
    }

    @Test("nothing answered on any port yields no device")
    func nothingFound() {
        let result = CameraDiscovery.resolveDiscovery(
            host: "192.168.1.50", webHits: [], baichuanConfirmed: false
        )
        #expect(result == nil)
    }
}
