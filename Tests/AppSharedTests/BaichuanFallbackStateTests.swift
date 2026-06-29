import Testing
import Foundation
@testable import AppShared

/// GitHub #76 — when a camera's HTTP/HTTPS CGI API is off and only Baichuan
/// (port 9000) answers, `CameraSession` connects over Baichuan and builds its
/// device/channel state from the login reply. These pin that pure mapping so
/// the session always comes up with a usable single channel.
@Suite("CameraSession Baichuan fallback state (#76)")
struct BaichuanFallbackStateTests {

    @Test("the login device name becomes the device + channel name")
    func usesDeviceName() {
        let (info, channels) = CameraSession.baichuanFallbackState(
            deviceName: "Front Door", fallbackName: "ignored"
        )
        #expect(info.name == "Front Door")
        #expect(info.channelNum == 1)
        #expect(channels.count == 1)
        #expect(channels[0].channel == 0)
        #expect(channels[0].name == "Front Door")
        #expect(channels[0].isOnline)
    }

    @Test("an empty login name falls back to the saved camera name")
    func fallsBackToEntryName() {
        let (info, channels) = CameraSession.baichuanFallbackState(
            deviceName: "", fallbackName: "Garage"
        )
        #expect(info.name == "Garage")
        #expect(channels[0].name == "Garage")
    }

    @Test("with no name anywhere, a generic label keeps the channel usable")
    func genericFallback() {
        let (info, _) = CameraSession.baichuanFallbackState(
            deviceName: "   ", fallbackName: ""
        )
        #expect(info.name == "Camera")
    }

    @Test("whitespace around the login name is trimmed")
    func trimsWhitespace() {
        let (info, _) = CameraSession.baichuanFallbackState(
            deviceName: "  Patio  ", fallbackName: "x"
        )
        #expect(info.name == "Patio")
    }
}
