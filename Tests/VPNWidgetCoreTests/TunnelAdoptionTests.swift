import Foundation
import Testing
@testable import VPNWidgetCore

@Suite struct TunnelAdoptionTests {
    static let installed: VPNProfile = {
        var tunnel = TunnelConfig(name: "office", kind: .openfortivpn, host: "gw.example.com", port: 8443, saml: true)
        tunnel.realm = "sso"
        tunnel.trustedCert = "ab12"
        var p = VPNProfile(tunnel: tunnel, displayName: "Office")
        p.checkURL = URL(string: "https://wiki.example.com/")
        p.autoConnect = true
        p.dnsDomains = ["example.com"]
        p.dnsServers = ["192.0.2.53"]
        return p
    }()

    static func lookup(_ name: String) -> VPNProfile? { name == "office" ? installed : nil }

    /// What the directory says about a tunnel: its id, name and client only.
    static func service(_ profile: VPNProfile) -> DiscoveredService {
        DiscoveredService(id: profile.id, name: profile.displayName, enabled: true, providerBundleID: profile.tunnel?.kind.providerBundleID)
    }

    @Test func hidingAndShowingATunnelKeepsItsConfig() {
        var profiles = [VPNProfile.test("wg", check: nil), Self.installed]
        profiles.removeAll { $0.id == Self.installed.id }
        if let shown = TunnelAdoption.profile(adopting: Self.service(Self.installed), installed: Self.lookup) { profiles.append(shown) }
        #expect(profiles == [.test("wg", check: nil), Self.installed])
        #expect(profiles[1].isOwnTunnel)
        #expect(profiles[1].tunnel?.realm == "sso")
        #expect(profiles[1].autoConnect)
        #expect(profiles[1].dnsServers == ["192.0.2.53"])
    }

    @Test func otherAppsProfilesStartFromDefaults() {
        let service = DiscoveredService(id: "80F9E491", name: "Lab", enabled: true, providerBundleID: "com.wireguard.macos.network-extension")
        let p = TunnelAdoption.profile(adopting: service) { _ in Self.installed }
        #expect(p == VPNProfile(adopting: service))
        #expect(p?.tunnel == nil)
    }

    @Test func aTunnelWithoutAnInstalledCopyIsNotAdopted() {
        let service = DiscoveredService(id: "tunnel:gone", name: "gone", enabled: true, providerBundleID: nil)
        #expect(TunnelAdoption.profile(adopting: service, installed: Self.lookup) == nil)
        // A copy of another tunnel, or one without a config, is no better.
        #expect(TunnelAdoption.profile(adopting: service) { _ in Self.installed } == nil)
        #expect(TunnelAdoption.profile(adopting: service) { _ in VPNProfile(id: "tunnel:gone", displayName: "Gone", providerKind: .openfortivpn) } == nil)
    }

    @Test func repairFillsALostConfig() {
        let broken = VPNProfile(adopting: Self.service(Self.installed))
        #expect(broken.tunnel == nil)
        let repaired = TunnelAdoption.repaired([.test("wg", check: nil), broken], installed: Self.lookup)
        #expect(repaired == [.test("wg", check: nil), Self.installed])
    }

    @Test func repairKeepsWhatWasSetSince() {
        var broken = VPNProfile(adopting: Self.service(Self.installed))
        broken.displayName = "Head office"
        broken.checkURL = URL(string: "https://git.example.com/")
        broken.dnsDomains = ["example.org"]
        let repaired = TunnelAdoption.repaired([broken], installed: Self.lookup)[0]
        #expect(repaired.tunnel == Self.installed.tunnel)
        #expect(repaired.displayName == "Head office")
        #expect(repaired.checkURL == URL(string: "https://git.example.com/"))
        #expect(repaired.dnsDomains == ["example.org"])
        #expect(repaired.dnsServers == ["192.0.2.53"])
        #expect(repaired.autoConnect)
    }

    @Test func repairLeavesOtherProfilesAlone() {
        var healthy = Self.installed
        healthy.tunnel?.host = "new.example.com"
        healthy.autoConnect = false
        let lost = VPNProfile(id: "tunnel:gone", displayName: "Gone", providerKind: .openconnect)
        let profiles = [VPNProfile.test("wg"), healthy, lost]
        #expect(TunnelAdoption.repaired(profiles) { _ in Self.installed } == profiles)
        #expect(TunnelAdoption.repaired(profiles) { _ in nil } == profiles)
    }
}
