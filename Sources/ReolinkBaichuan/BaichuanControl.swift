import Foundation
import OSLog
import ReolinkAPI

private let log = Logger(subsystem: "com.reolens.baichuan", category: "control")

/// Control-plane commands carried over the Baichuan port-9000 protocol, for
/// cameras that ship the HTTP/HTTPS CGI API off (newer Reolink firmware, e.g.
/// the CX410). These mirror the CGI control surface so a `CameraSession` can
/// fall back to Baichuan when the web API is unreachable (GitHub #76).
///
/// Wire formats follow `reolink_aio/baichuan` (the same reference the rest of
/// this module cites). Each channel-targeted modern command carries the
/// routing `<Extension>` XML that Home Hubs / NVRs need; see
/// `Wire/BcMessage.swift` for the AES split-stream layout.
///
/// Scope note: PTZ lands here first because it's a clean single
/// request/response. **Snapshot** (cmd_id 109) is intentionally *not* here yet
/// — the camera streams the JPEG back across multiple Baichuan frames keyed by
/// msg_id, which needs a multi-frame accumulator the current single-reply
/// `sendAndAwait` transport doesn't provide. Device info comes from the login
/// reply's `<DeviceInfo>` (see `BaichuanClient.login()`), so no separate
/// command is needed for the connect path.
extension BaichuanClient {

    /// Pan / tilt / zoom a camera over Baichuan (cmd_id 18, `PtzControl`).
    ///
    /// Mirrors `reolink_aio/baichuan/xmls.py::PtzControl`:
    /// `<body><PtzControl version="1.1"><channelId/><command/></PtzControl></body>`.
    /// Throws `BaichuanError.unexpectedReply` if the hub answers with a
    /// non-200 response code.
    ///
    /// On-device validation (CX410) confirms the exact `<command>` token
    /// vocabulary; `ptzCommandToken(for:)` uses the canonical Reolink op
    /// tokens shared with the CGI `PtzCtrl` command.
    public func ptzControl(channel: UInt8, op: PtzOp) async throws {
        let command = Self.ptzCommandToken(for: op)
        log.info("Baichuan PTZ channel=\(channel) op=\(command, privacy: .public)")
        let body = Self.buildPtzControlXML(channel: Int(channel), command: command)
        let reply = try await sendModernChannelCommand(
            cmdID: BcMessageID.ptzControl,
            channelID: channel,
            body: body,
            stage: "ptzControl"
        )
        guard reply.header.responseCode == 200 else {
            throw BaichuanError.unexpectedReply(
                msgID: reply.header.msgID,
                code: reply.header.responseCode
            )
        }
    }

    /// The Baichuan `<command>` token for an app `PtzOp`. The Baichuan control
    /// plane uses the same canonical Reolink op tokens as the CGI `PtzCtrl`
    /// command (`Left`, `Right`, `ZoomInc`, …), so the op's raw value *is* the
    /// token. Pure + unit-pinned. GitHub #76.
    static func ptzCommandToken(for op: PtzOp) -> String { op.rawValue }

    /// Build the `PtzControl` request body. Pure so the wire shape is
    /// unit-pinned without a live camera.
    static func buildPtzControlXML(channel: Int, command: String) -> Data {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" ?>
        <body>
        <PtzControl version="1.1">
        <channelId>\(channel)</channelId>
        <command>\(command)</command>
        </PtzControl>
        </body>

        """
        return Data(xml.utf8)
    }

    /// Send a modern, channel-routed Baichuan command (class 0x6414) with an
    /// XML body and the `<Extension>` channel-routing prefix. Mirrors the
    /// helper `BaichuanAlarmVideo` uses for `findAlarmVideo`.
    func sendModernChannelCommand(
        cmdID: UInt32,
        channelID: UInt8,
        body: Data,
        stage: String,
        timeout: TimeInterval = 8
    ) async throws -> BcMessage {
        let msgNum = await nextMessageNumber()
        let header = BcHeader(
            msgID: cmdID,
            bodyLength: 0,
            channelID: channelID,
            streamType: 0,
            msgNum: msgNum,
            responseCode: 0,
            msgClass: BcConstants.classModernWithOffset,
            payloadOffset: 0
        )
        let ext = BcXmlBody.channelExtension(channel: Int(channelID))
        let message = BcMessage(header: header, body: body, extensionBody: ext)
        return try await sendAndAwait(message, timeout: timeout, stage: stage)
    }
}
