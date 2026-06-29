import Testing
import Foundation
import ReolinkAPI
@testable import ReolinkBaichuan

/// A scripted `BcMessageTransport` for testing control-plane commands without
/// a socket: it records every message handed to `sendAndAwait` and returns a
/// canned reply with a configurable response code. Lets us pin the *framing*
/// of a Baichuan command (cmd_id, class, channel-extension, XML body) — the
/// part that's verifiable off-device — independently of a real CX410.
actor ScriptedTransport: BcMessageTransport {
    private(set) var sent: [BcMessage] = []
    private var nextNum: UInt16 = 0
    private var cipher: BcCipher = .unencrypted
    var replyCode: UInt16 = 200

    var lastSent: BcMessage? { sent.last }

    func connect() async throws {}
    func close() async {}
    func subscribe() async -> AsyncStream<BcMessage> {
        AsyncStream { $0.finish() }
    }
    func nextMessageNumber() async -> UInt16 { defer { nextNum &+= 1 }; return nextNum }
    func currentCipher() async -> BcCipher { cipher }
    func setCipher(_ new: BcCipher) async { cipher = new }
    func setReplyCode(_ code: UInt16) { replyCode = code }

    func sendAndAwait(_ message: BcMessage, timeout: TimeInterval, stage: String) async throws -> BcMessage {
        sent.append(message)
        let header = BcHeader(
            msgID: message.header.msgID,
            bodyLength: 0,
            channelID: message.header.channelID,
            streamType: 0,
            msgNum: message.header.msgNum,
            responseCode: replyCode,
            msgClass: BcConstants.classModernWithOffset,
            payloadOffset: 0
        )
        return BcMessage(header: header, body: Data())
    }
}

@Suite("Baichuan control-plane commands (#76)")
struct BaichuanControlTests {

    // MARK: - Pure wire-shape pins

    @Test("PTZ command token is the canonical Reolink op string", arguments: [
        (PtzOp.left, "Left"), (.right, "Right"), (.up, "Up"), (.down, "Down"),
        (.zoomIn, "ZoomInc"), (.zoomOut, "ZoomDec"), (.stop, "Stop")
    ])
    func ptzTokenMapping(op: PtzOp, expected: String) {
        #expect(BaichuanClient.ptzCommandToken(for: op) == expected)
    }

    @Test("PtzControl body matches the reolink_aio schema")
    func ptzBodyShape() {
        let data = BaichuanClient.buildPtzControlXML(channel: 2, command: "Left")
        let xml = String(data: data, encoding: .utf8) ?? ""
        #expect(xml.contains("<PtzControl version=\"1.1\">"))
        #expect(BcXmlBody.firstTagContent(in: xml, tag: "channelId") == "2")
        #expect(BcXmlBody.firstTagContent(in: xml, tag: "command") == "Left")
    }

    // MARK: - Framing through a scripted transport

    @Test("ptzControl sends cmd_id 18, modern class, with channel routing")
    func ptzFraming() async throws {
        let transport = ScriptedTransport()
        let client = BaichuanClient(
            credentials: BaichuanCredentials(host: "192.168.1.50", username: "admin", password: "x"),
            transport: transport
        )
        try await client.ptzControl(channel: 3, op: .right)

        let sent = try #require(await transport.lastSent)
        #expect(sent.header.msgID == BcMessageID.ptzControl)        // 18
        #expect(sent.header.msgClass == BcConstants.classModernWithOffset)
        #expect(sent.header.channelID == 3)

        // The channel-routing <Extension> rides ahead of the body.
        let ext = String(data: sent.extensionBody ?? Data(), encoding: .utf8) ?? ""
        #expect(BcXmlBody.firstTagContent(in: ext, tag: "channelId") == "3")

        let body = String(data: sent.body, encoding: .utf8) ?? ""
        #expect(body.contains("<PtzControl"))
        #expect(BcXmlBody.firstTagContent(in: body, tag: "command") == "Right")
    }

    @Test("a non-200 PTZ reply surfaces as an error")
    func ptzNon200Throws() async throws {
        let transport = ScriptedTransport()
        await transport.setReplyCode(400)
        let client = BaichuanClient(
            credentials: BaichuanCredentials(host: "192.168.1.50", username: "admin", password: "x"),
            transport: transport
        )
        await #expect(throws: BaichuanError.self) {
            try await client.ptzControl(channel: 0, op: .left)
        }
    }
}
