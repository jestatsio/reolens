import Testing
import Foundation
@testable import AppShared

/// GitHub #71 — "Pick your local network". The auto-detect scanner was
/// locking onto the wrong subnet (users saw it sweep `10.0.0.x` even on a
/// `192.168.1.0/24` LAN). The root cause: `primarySubnetPrefix()` returned
/// the first interface in `10.0.0.0/8` OR `192.168.0.0/16` it happened to
/// enumerate, so a cellular (`pdp_ip0`, carrier 10.x NAT), VPN (`utun*`), or
/// virtualization (`bridge*`) address ahead of the real Wi-Fi/Ethernet LAN
/// won. These tests pin the interface-ranking fix on the pure selector so
/// the behavior is verifiable without a live network stack.
@Suite("CameraDiscovery subnet selection (#71)")
struct CameraDiscoverySubnetTests {

    private func iface(_ name: String, _ ip: String) -> CameraDiscovery.InterfaceAddress {
        CameraDiscovery.InterfaceAddress(name: name, ipv4: ip)
    }

    @Test("Wi-Fi LAN wins over a cellular 10.x interface enumerated first")
    func wifiBeatsCellular() {
        // The exact #71 scenario: an iPhone on Wi-Fi 192.168.1.x whose
        // carrier hands pdp_ip0 a 10.x address, listed before en0.
        let prefix = CameraDiscovery.selectPrimarySubnetPrefix(from: [
            iface("pdp_ip0", "10.34.12.9"),
            iface("en0", "192.168.1.42")
        ])
        #expect(prefix == "192.168.1")
    }

    @Test("Wi-Fi/Ethernet LAN wins over a VPN utun 10.x tunnel")
    func lanBeatsVPNTunnel() {
        let prefix = CameraDiscovery.selectPrimarySubnetPrefix(from: [
            iface("utun3", "10.8.0.6"),
            iface("en0", "192.168.0.15")
        ])
        #expect(prefix == "192.168.0")
    }

    @Test("A legitimate 10.x home LAN on en0 is still detected")
    func realTenDotLanIsKept() {
        // Comcast/Xfinity gateways default to 10.0.0.0/24 — a real LAN.
        let prefix = CameraDiscovery.selectPrimarySubnetPrefix(from: [
            iface("en0", "10.0.0.23")
        ])
        #expect(prefix == "10.0.0")
    }

    @Test("Interface type dominates IP range: en0 10.x beats a 192.168 VPN")
    func interfaceTypeDominatesRange() {
        let prefix = CameraDiscovery.selectPrimarySubnetPrefix(from: [
            iface("utun0", "192.168.50.2"),
            iface("en0", "10.0.0.5")
        ])
        #expect(prefix == "10.0.0")
    }

    @Test("Self-assigned link-local (169.254) is skipped")
    func skipsLinkLocal() {
        let prefix = CameraDiscovery.selectPrimarySubnetPrefix(from: [
            iface("en0", "169.254.4.4"),
            iface("en1", "192.168.2.7")
        ])
        #expect(prefix == "192.168.2")
    }

    @Test("Loopback and empty inputs yield nil")
    func loopbackAndEmptyAreNil() {
        #expect(CameraDiscovery.selectPrimarySubnetPrefix(from: []) == nil)
        #expect(CameraDiscovery.selectPrimarySubnetPrefix(from: [
            iface("lo0", "127.0.0.1")
        ]) == nil)
    }

    @Test("Two Wi-Fi/Ethernet interfaces tie-break to the earlier (primary) one")
    func tieBreaksToEarlierInterface() {
        let prefix = CameraDiscovery.selectPrimarySubnetPrefix(from: [
            iface("en0", "192.168.1.5"),
            iface("en1", "192.168.9.9")
        ])
        #expect(prefix == "192.168.1")
    }

    @Test("Private LAN beats a public address on equal-class interfaces")
    func privateBeatsPublicWithinSameClass() {
        let prefix = CameraDiscovery.selectPrimarySubnetPrefix(from: [
            iface("en1", "203.0.113.7"),
            iface("en0", "192.168.1.4")
        ])
        #expect(prefix == "192.168.1")
    }

    @Test("172.16/12 private range is recognized")
    func recognizesSeventeenTwoRange() {
        #expect(CameraDiscovery.isPrivateIPv4("172.16.5.9"))
        #expect(CameraDiscovery.isPrivateIPv4("172.31.0.1"))
        #expect(!CameraDiscovery.isPrivateIPv4("172.32.0.1"))
        #expect(!CameraDiscovery.isPrivateIPv4("172.15.0.1"))
    }

    @Test("Cellular/VPN/virtualization names rank below en*/eth*")
    func secondaryInterfacesRankBelowLAN() {
        #expect(CameraDiscovery.interfaceClassRank(name: "en0") == 0)
        #expect(CameraDiscovery.interfaceClassRank(name: "eth0") == 0)
        for secondary in ["pdp_ip0", "utun4", "ipsec0", "ppp0", "bridge100", "vmnet1", "awdl0", "llw0"] {
            #expect(CameraDiscovery.interfaceClassRank(name: secondary) > CameraDiscovery.interfaceClassRank(name: "en0"),
                    "\(secondary) should rank below en0")
        }
    }
}
