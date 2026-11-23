import Foundation
import Testing
@testable import VPNWidgetCore

// Keys that are 32 bytes of base64 and plainly not keys.
private let privateKey = "PRIVATEKEYPRIVATEKEYPRIVATEKEYPRIVATEKEYPRI="
private let publicKey = "PUBLICKEYPUBLICKEYPUBLICKEYPUBLICKEYPUBLICA="
private let otherPublicKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
private let presharedKey = "PRESHAREDKEYPRESHAREDKEYPRESHAREDKEYPRESHAQ="

private let amneziaConf = """
# exported for a laptop
[Interface]
PrivateKey = \(privateKey)
Address = 10.8.0.2/32, fd00:8::2/128
address = 10.8.0.3
DNS = 10.8.0.1, corp.example
dns = 10.8.0.53
MTU = 1380
Jc = 4
Jmin = 40
Jmax = 70
S1 = 81
S2 = 62
H1 = 1493857235
H2 = 492837465
H3 = 918273645
H4 = 564738291
I1 = <b 0x084481800001000300000000>
PostUp = /bin/sh -c 'touch /tmp/owned'
PreDown = echo bye

[Peer]
PublicKey = \(publicKey)
PresharedKey = \(presharedKey)   # shared with the server
Endpoint = VPN.Example.com:51820
AllowedIPs = 10.8.0.0/24, 10.20.30.40/16
AllowedIPs = fd00:8::/64
PersistentKeepalive = 25

[peer]
publickey=\(otherPublicKey)
endpoint=[2001:db8::1]:443
allowedips=192.0.2.0/24,10.8.0.0/24
"""

private func conf(interface: String = "Address = 10.8.0.2/32", peer: String = "AllowedIPs = 10.8.0.0/24") -> String {
    """
    [Interface]
    PrivateKey = \(privateKey)
    \(interface)
    [Peer]
    PublicKey = \(publicKey)
    Endpoint = 203.0.113.5:51820
    \(peer)
    """
}

private func refusal(_ text: String) -> String? {
    do {
        _ = try WireGuardConf.parse(text)
        return nil
    } catch {
        return "\(error)"
    }
}

@Suite struct IPNetworkTests {
    @Test func parsing() {
        #expect(IPNetwork("10.8.0.2/32")?.description == "10.8.0.2/32")
        #expect(IPNetwork("10.8.0.2")?.description == "10.8.0.2/32")
        #expect(IPNetwork("2001:DB8:0:0::1/64")?.description == "2001:db8::1/64")
        #expect(IPNetwork("fd00::2")?.prefix == 128)
        #expect(IPNetwork("0.0.0.0/0")?.prefix == 0)
        #expect(IPNetwork("::/0")?.isIPv6 == true)
    }

    @Test func refusesWhatIsNotAnAddress() {
        for bad in ["", "10.8.0.2/33", "fd00::2/129", "10.8.0.2/", "10.8.0.2/-1", "10.8.0.2/3 2", "10.8.0/24", "10.8.0.2/24/1", "vpn.example.com", "10.8.0.2 -alias",
                    "10.8.0.2;reboot", "$(id)", "-interface", "10.8.0.2/٣", "fe80::1%en0", " 10.8.0.2"] {
            #expect(IPNetwork(bad) == nil, "\(bad)")
        }
    }

    @Test func networksAndContainment() {
        #expect(IPNetwork("10.20.30.40/16")?.network.description == "10.20.0.0/16")
        #expect(IPNetwork("10.20.30.40/19")?.network.description == "10.20.0.0/19")
        #expect(IPNetwork("192.0.2.77/32")?.network.description == "192.0.2.77/32")
        #expect(IPNetwork("2001:db8:1:2::9/48")?.network.description == "2001:db8:1::/48")
        #expect(IPNetwork("203.0.113.9/0")?.network.description == "0.0.0.0/0")
        let net = IPNetwork("203.0.113.0/24")!
        #expect(net.contains(IPNetwork("203.0.113.5")!))
        #expect(!net.contains(IPNetwork("203.0.114.5")!))
        #expect(!net.contains(IPNetwork("2001:db8::1")!))
        #expect(IPNetwork("0.0.0.0/1")!.contains(IPNetwork("100.64.0.1")!))
        #expect(!IPNetwork("0.0.0.0/1")!.contains(IPNetwork("203.0.113.5")!))
    }
}

@Suite struct WireGuardConfTests {
    @Test func splitsTheFileAsWgQuickDoes() throws {
        let c = try WireGuardConf.parse(amneziaConf)
        #expect(c.addresses.map(\.description) == ["10.8.0.2/32", "fd00:8::2/128", "10.8.0.3/32"])
        #expect(c.dnsServers == ["10.8.0.1", "10.8.0.53"])
        #expect(c.dnsSearchDomains == ["corp.example"])
        #expect(c.mtu == 1380)
        #expect(c.ignoredKeys == ["PostUp", "PreDown"])
        #expect(c.peers.count == 2)
        #expect(c.peers[0].endpoint == .init(host: "vpn.example.com", port: 51820))
        #expect(c.peers[0].keepalive)
        #expect(c.peers[1].endpoint?.description == "[2001:db8::1]:443")
        #expect(!c.peers[1].keepalive)
        #expect(c.allowedIPs.map(\.description) == ["10.8.0.0/24", "10.20.0.0/16", "fd00:8::/64", "192.0.2.0/24"])
        #expect(c.routes == c.allowedIPs)
        #expect(!c.takesDefaultRoute)
        #expect(c.secrets == [privateKey, presharedKey])
    }

    @Test func setconfKeepsEverythingButWgQuicksOwnKeys() throws {
        let c = try WireGuardConf.parse(amneziaConf)
        let lines = c.setconf.split(separator: "\n").map(String.init)
        // The obfuscation parameters and the keys go through as written.
        for kept in ["[Interface]", "PrivateKey = \(privateKey)", "Jc = 4", "Jmin = 40", "Jmax = 70", "S1 = 81", "S2 = 62", "H1 = 1493857235", "H2 = 492837465",
                     "H3 = 918273645", "H4 = 564738291", "I1 = <b 0x084481800001000300000000>", "[Peer]", "PublicKey = \(publicKey)",
                     "PresharedKey = \(presharedKey)   # shared with the server", "Endpoint = VPN.Example.com:51820", "AllowedIPs = 10.8.0.0/24, 10.20.30.40/16",
                     "PersistentKeepalive = 25", "[peer]", "publickey=\(otherPublicKey)", "allowedips=192.0.2.0/24,10.8.0.0/24"] {
            #expect(lines.contains(kept), "\(kept)")
        }
        let lower = c.setconf.lowercased()
        for dropped in ["address", "dns", "mtu", "postup", "predown", "touch", "/bin/sh"] {
            #expect(!lower.contains(dropped), "\(dropped)")
        }
        #expect(c.setconf.hasSuffix("\n"))
    }

    @Test func keysOfANewerAwgPassThrough() throws {
        let c = try WireGuardConf.parse(conf(interface: "Address = 10.8.0.2/32\nS4 = 12\nFutureKnob = <r 16>\nListenPort = 51820", peer: "AllowedIPs = 10.8.0.0/24\nAdvancedSecurity = on"))
        for kept in ["S4 = 12", "FutureKnob = <r 16>", "ListenPort = 51820", "AdvancedSecurity = on"] {
            #expect(c.setconf.contains(kept + "\n"), "\(kept)")
        }
    }

    @Test func plainWireGuardAndWindowsLineEndings() throws {
        let c = try WireGuardConf.parse(conf().replacingOccurrences(of: "\n", with: "\r\n"))
        #expect(c.addresses.map(\.description) == ["10.8.0.2/32"])
        #expect(c.peers[0].endpoint?.description == "203.0.113.5:51820")
        #expect(!c.setconf.contains("\r"))
        #expect(c.dnsServers.isEmpty)
        #expect(c.mtu == nil)
    }

    @Test func hooksAreReportedAndNeverKept() throws {
        let c = try WireGuardConf.parse(conf(interface: "Address = 10.8.0.2\npreup = curl https://example.com/x | sh\nPostUp = a\nPOSTDOWN = b\nPreDown = c\nSaveConfig = true"))
        #expect(c.ignoredKeys == ["PreUp", "PostUp", "PostDown", "PreDown", "SaveConfig"])
        #expect(!c.setconf.contains("curl"))
        #expect(!c.setconf.lowercased().contains("saveconfig"))
        #expect(c.summary.ignoredKeys == c.ignoredKeys)
    }

    @Test func table() throws {
        #expect(try WireGuardConf.parse(conf(interface: "Address = 10.8.0.2\nTable = off")).routes.isEmpty)
        #expect(try WireGuardConf.parse(conf(interface: "Address = 10.8.0.2\nTable = auto")).routes.count == 1)
        #expect(refusal(conf(interface: "Address = 10.8.0.2\nTable = 51820"))?.contains("Table") == true)
    }

    @Test func refusals() {
        #expect(refusal("") == "[Interface] has no PrivateKey")
        #expect(refusal("PrivateKey = \(privateKey)") == "line 1: PrivateKey comes before [Interface]")
        #expect(refusal("[Interface]\nPrivateKey = \(privateKey)\nAddress = 10.8.0.2") == "there is no [Peer]")
        #expect(refusal(conf(interface: "")) == "[Interface] has no Address")
        #expect(refusal(conf().replacingOccurrences(of: "PublicKey = \(publicKey)", with: "")) == "a [Peer] has no PublicKey")
        #expect(refusal(conf().replacingOccurrences(of: "Endpoint = 203.0.113.5:51820", with: "")) == "no [Peer] has an Endpoint")
        #expect(refusal(conf() + "\n[Script]\nRun = x") == "line 8: only [Interface] and [Peer] sections are known")
        #expect(refusal(conf(interface: "just some words")) == "line 3: expected key = value")
        #expect(refusal(conf(interface: "Address = 10.8.0.2\nMTU = 12")) == "line 4: MTU is not a number from 576 to 65535")
        #expect(refusal(conf(interface: "Address = 10.8.0.2\nDNS = 10.8.0.1/24")) == "line 4: DNS is neither an IP address nor a domain")
        #expect(refusal(conf(peer: "PersistentKeepalive = soon")) == "line 7: PersistentKeepalive is not a number of seconds")
        #expect(refusal(conf() + "\u{0}") == "the file has control characters in it")
        #expect(refusal(conf() + "\n" + String(repeating: "# padding\n", count: 7000)) == "the file is too large for a tunnel config")
    }

    @Test func nothingShellLikeGetsThroughTheParsedFields() {
        for address in ["10.8.0.2/32 alias", "10.8.0.2;reboot", "$(id)", "`id`", "-alias", "10.8.0.2/32/1", "10.8.0.2|x"] {
            #expect(refusal(conf(interface: "Address = \(address)"))?.hasSuffix("Address is not an IP address with an optional /prefix") == true, "\(address)")
        }
        for allowed in ["10.8.0.0/24 -interface en0", "default", "10.8.0.0/40", "$(id)/8", "10.8.0.0/24;x"] {
            #expect(refusal(conf(peer: "AllowedIPs = \(allowed)"))?.hasSuffix("AllowedIPs is not a list of IP prefixes") == true, "\(allowed)")
        }
        for endpoint in ["vpn.example.com", "vpn.example.com:0", "vpn.example.com:70000", "vpn example.com:51820", "-gateway:51820", "$(id):51820", "vpn.example.com;x:51820",
                         "2001:db8::1:51820", "[vpn.example.com]:51820", "[203.0.113.5]:51820", "a/b:51820", ":51820"] {
            #expect(WireGuardConf.endpoint(endpoint) == nil, "\(endpoint)")
        }
        #expect(WireGuardConf.endpoint("203.0.113.5:51820")?.host == "203.0.113.5")
        #expect(WireGuardConf.endpoint("Edge-1.VPN.example.com:443")?.host == "edge-1.vpn.example.com")
    }

    @Test func interfaceNames() {
        #expect(WireGuardConf.isInterfaceName("utun0"))
        #expect(WireGuardConf.isInterfaceName("utun12"))
        for bad in ["utun", "utun-1", "en0", "utun1 up", "utun1;x", "utun123456", "Utun1", "utun١"] {
            #expect(!WireGuardConf.isInterfaceName(bad), "\(bad)")
        }
    }

    @Test func aBadKeyIsRefusedWithoutBeingQuoted() {
        let almost = String(privateKey.dropLast(2)) + "=="
        for text in [conf().replacingOccurrences(of: privateKey, with: almost), conf().replacingOccurrences(of: privateKey, with: "hunter2"),
                     conf(peer: "PresharedKey = not-a-key-at-all")] {
            let reason = refusal(text)
            #expect(reason?.contains("is not a 32-byte base64 key") == true)
            #expect(reason?.contains(almost) == false)
            #expect(reason?.contains("hunter2") == false)
            #expect(reason?.contains("not-a-key") == false)
        }
    }

    @Test func aKeyInTheWrongSectionIsRefusedHere() {
        // awg would refuse it too, quoting the line into the log.
        #expect(refusal(conf(peer: "PrivateKey = \(privateKey)")) == "line 7: PrivateKey belongs in [Interface]")
        #expect(refusal(conf(interface: "Address = 10.8.0.2\nPresharedKey = \(presharedKey)")) == "line 4: PresharedKey belongs in [Peer]")
    }

    @Test func defaultRoutes() throws {
        func parsed(_ allowed: String) throws -> WireGuardConf { try WireGuardConf.parse(conf(peer: "AllowedIPs = \(allowed)")) }
        var c = try parsed("0.0.0.0/0")
        #expect(c.takesDefaultRoute)
        #expect(c.routes.map(\.description) == ["0.0.0.0/1", "128.0.0.0/1"])
        c = try parsed("0.0.0.0/0, ::/0")
        #expect(c.takesDefaultRoute)
        #expect(c.routes.map(\.description) == ["0.0.0.0/1", "128.0.0.0/1", "::/1", "8000::/1"])
        #expect(c.summary.allowedIPs == ["0.0.0.0/0", "::/0"])
        c = try parsed("::/0, 10.8.0.0/24")
        #expect(c.takesDefaultRoute)
        c = try parsed("0.0.0.0/1, 128.0.0.0/1")
        #expect(c.takesDefaultRoute)
        #expect(c.routes.map(\.description) == ["0.0.0.0/1", "128.0.0.0/1"])
        c = try parsed("::/1, 8000::/1")
        #expect(c.takesDefaultRoute)
        c = try parsed("203.0.113.9/0")
        #expect(c.takesDefaultRoute)
        c = try parsed("0.0.0.0/1, 10.8.0.0/24")
        #expect(!c.takesDefaultRoute)
        c = try parsed("128.0.0.0/1, ::/1")
        #expect(!c.takesDefaultRoute)
        c = try parsed("0.0.0.0/0, 0.0.0.0/1")
        #expect(c.routes.map(\.description) == ["0.0.0.0/1", "128.0.0.0/1"])
        #expect(try WireGuardConf.parse(conf(interface: "Address = 10.8.0.2\nTable = off", peer: "AllowedIPs = 0.0.0.0/0")).routes.isEmpty)
    }

    @Test func theSummaryAndTheProfileCarryNoKeys() throws {
        let c = try WireGuardConf.parse(amneziaConf)
        #expect(c.summary == WireGuardSummary(
            endpoints: ["vpn.example.com:51820", "[2001:db8::1]:443"], addresses: ["10.8.0.2/32", "fd00:8::2/128", "10.8.0.3/32"],
            allowedIPs: ["10.8.0.0/24", "10.20.0.0/16", "fd00:8::/64", "192.0.2.0/24"], dnsServers: ["10.8.0.1", "10.8.0.53"], mtu: 1380,
            defaultRoute: false, keepalive: false, ignoredKeys: ["PostUp", "PreDown"]
        ))
        var tunnel = TunnelConfig(name: "lab", kind: .amneziawg, host: "", port: 443)
        tunnel.apply(c)
        #expect(tunnel.host == "vpn.example.com")
        #expect(tunnel.port == 51820)
        let profile = VPNProfile(tunnel: tunnel, displayName: "Lab")
        let json = String(decoding: try TunnelState.encoder.encode(profile), as: UTF8.self)
        for secret in [privateKey, presharedKey, publicKey, "touch", "Jc"] {
            #expect(!json.contains(secret), "\(secret)")
        }
        let back = try TunnelState.decoder.decode(VPNProfile.self, from: Data(json.utf8))
        #expect(back == profile)
        #expect(back.tunnel?.wireGuard?.endpoints.first == "vpn.example.com:51820")
    }

    @Test func scrubbing() throws {
        let c = try WireGuardConf.parse(amneziaConf)
        #expect(c.scrub("Key is not the correct length or format: `\(privateKey)'") == "Key is not the correct length or format: `(hidden)'")
        #expect(c.scrub("psk \(presharedKey) for \(publicKey)") == "psk (hidden) for \(publicKey)")
    }
}

@Suite struct WireGuardKindTests {
    @Test func theKindIsAnOwnTunnelNotTheAppsProfile() {
        let p = VPNProfile(tunnel: TunnelConfig(name: "lab", kind: .amneziawg, host: "vpn.example.com", port: 51820), displayName: "Lab")
        #expect(p.providerKind == .amneziawgGo)
        #expect(p.isOwnTunnel)
        #expect(ProviderKind.amneziawgGo.isOwnTunnel)
        #expect(!ProviderKind.amneziawg.isOwnTunnel)
        #expect(ProviderKind.amneziawgGo.clientBundleIDs.isEmpty)
        #expect(!ProviderKind.amneziawgGo.signsInInteractively)
        #expect(ProviderKind(bundleID: TunnelConfig.Kind.amneziawg.providerBundleID) == .amneziawgGo)
        #expect(ProviderKind(bundleID: "org.amnezia.awg.network-extension") == .amneziawg)
    }

    @Test func coding() throws {
        let old = #"{"name":"lab","kind":"amneziawg","host":"2001:db8::1","port":51820}"#
        let t = try JSONDecoder().decode(TunnelConfig.self, from: Data(old.utf8))
        #expect(t.kind == .amneziawg)
        #expect(t.wireGuard == nil)
        // The endpoint is not a gateway URL: nothing to clean up.
        #expect(t.normalized == t)
        let other = try JSONDecoder().decode(TunnelConfig.self, from: Data(#"{"name":"x","kind":"openconnect","host":"h"}"#.utf8))
        #expect(other.wireGuard == nil)
        #expect(TunnelConfig.LogLevel.trace.toolArguments(.amneziawg).isEmpty)
    }

    @Test func stateCarriesTheDefaultRoute() throws {
        let s = TunnelState(phase: .connected, since: Date(timeIntervalSince1970: 1_700_000_000), defaultRoute: true)
        let back = try TunnelState.decoder.decode(TunnelState.self, from: try TunnelState.encoder.encode(s))
        #expect(back.defaultRoute == true)
        let old = #"{"phase":"connected","since":"2026-11-02T10:00:00Z","signInAttempt":0,"dnsServers":[],"pid":1,"updated":"2026-11-02T10:00:00Z"}"#
        #expect(try TunnelState.decoder.decode(TunnelState.self, from: Data(old.utf8)).defaultRoute == nil)
    }

    @Test func tools() {
        #expect(TunnelFiles.wireGuardToolSources("awg", homebrewPrefix: "/opt/homebrew") == ["/opt/homebrew/bin/awg", "/usr/local/bin/awg"])
        #expect(TunnelFiles.wireGuardToolSources("awg", homebrewPrefix: "/usr/local") == ["/usr/local/bin/awg"])
        func status(_ present: Set<String>) -> TunnelFiles.WireGuardToolStatus {
            TunnelFiles.wireGuardToolStatus(homebrewPrefix: "/opt/homebrew") { present.contains($0) }
        }
        #expect(status(["/usr/local/libexec/vpn-widget/amneziawg-go", "/usr/local/libexec/vpn-widget/awg"]) == .ready)
        #expect(status([]) == .missing(["amneziawg-go", "awg"]))
        #expect(status(["/usr/local/bin/amneziawg-go", "/opt/homebrew/bin/awg"]) == .needsSetup(["amneziawg-go", "awg"]))
        #expect(status(["/usr/local/libexec/vpn-widget/amneziawg-go", "/usr/local/bin/amneziawg-go"]) == .missing(["awg"]))
        #expect(status(["/usr/local/libexec/vpn-widget/awg", "/usr/local/bin/amneziawg-go"]) == .needsSetup(["amneziawg-go"]))
    }
}

@Suite struct WireGuardStatusTests {
    @Test func latestHandshakes() {
        #expect(WireGuardStatus.latestHandshake(in: "") == nil)
        #expect(WireGuardStatus.latestHandshake(in: "\(publicKey)\t0\n") == nil)
        #expect(WireGuardStatus.latestHandshake(in: "\(publicKey)\t1795000000\n") == Date(timeIntervalSince1970: 1_795_000_000))
        #expect(WireGuardStatus.latestHandshake(in: "\(publicKey)\t1795000000\n\(otherPublicKey)\t0\n\(otherPublicKey)\t1795000100\n") == Date(timeIntervalSince1970: 1_795_000_100))
        #expect(WireGuardStatus.latestHandshake(in: "Unable to access interface: No such file or directory\n") == nil)
        #expect(WireGuardStatus.latestHandshake(in: "\(publicKey)\tnever\n") == nil)
    }

    @Test func aHandshakeIsFreshForThreeMinutes() {
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        #expect(WireGuardStatus.link(latestHandshake: nil, now: now) == .waiting)
        #expect(WireGuardStatus.link(latestHandshake: now, now: now) == .up)
        #expect(WireGuardStatus.link(latestHandshake: now.addingTimeInterval(-179), now: now) == .up)
        #expect(WireGuardStatus.link(latestHandshake: now.addingTimeInterval(-180), now: now) == .stale)
        #expect(WireGuardStatus.link(latestHandshake: now.addingTimeInterval(-86400), now: now) == .stale)
        // A clock that stepped back is no reason to drop the link.
        #expect(WireGuardStatus.link(latestHandshake: now.addingTimeInterval(5), now: now) == .up)
    }

    @Test func endpoints() {
        let output = "\(publicKey)\t203.0.113.5:51820\n\(otherPublicKey)\t[2001:db8::1]:443\n\(otherPublicKey)\t(none)\n\(publicKey)\t203.0.113.5:51820\n"
        #expect(WireGuardStatus.endpoints(in: output).map(\.address) == ["203.0.113.5", "2001:db8::1"])
        #expect(WireGuardStatus.endpoints(in: "\(publicKey)\tvpn.example.com:51820\n").isEmpty)
        #expect(WireGuardStatus.endpoints(in: "").isEmpty)
    }

    @Test func defaultGateway() {
        let inet = """
        Routing tables

        Internet:
        Destination        Gateway            Flags               Netif Expire
        default            link#28            UCSIg           bridge100      !
        default            192.0.2.1          UGScg                 en0
        0/1                utun6              USc                 utun6
        127                127.0.0.1          UCS                   lo0
        """
        #expect(WireGuardStatus.defaultGateway(inNetstat: inet) == "192.0.2.1")
        let inet6 = """
        Internet6:
        Destination                             Gateway                                 Flags               Netif Expire
        default                                 fe80::1%en0                             UGcg                  en0
        default                                 fe80::%utun0                            UGcIg               utun0
        """
        #expect(WireGuardStatus.defaultGateway(inNetstat: inet6) == "fe80::1%en0")
        #expect(WireGuardStatus.defaultGateway(inNetstat: "default            link#28            UCSIg           bridge100\n") == nil)
        #expect(WireGuardStatus.defaultGateway(inNetstat: "default  192.0.2.1;x  UGScg  en0\n") == nil)
        #expect(WireGuardStatus.defaultGateway(inNetstat: "default  fe80::1%en0;x  UGcg  en0\n") == nil)
        #expect(WireGuardStatus.defaultGateway(inNetstat: "") == nil)
    }

    @Test func routeInterface() {
        let output = """
           route to: 10.8.0.0
        destination: 10.8.0.0
               mask: 255.255.255.0
          interface: utun6
              flags: <UP,DONE,STATIC,PRCLONING>
        """
        #expect(WireGuardStatus.routeInterface(inRouteGet: output) == "utun6")
        #expect(WireGuardStatus.routeInterface(inRouteGet: "route: writing to routing socket: not in table\n") == nil)
    }

    @Test func commands() {
        let v4 = IPNetwork("10.8.0.2/24")!
        let v6 = IPNetwork("fd00:8::2/64")!
        #expect(WireGuardCommands.setconf(interface: "utun6", file: "/usr/local/etc/vpn-widget/generated/lab.conf") == ["setconf", "utun6", "/usr/local/etc/vpn-widget/generated/lab.conf"])
        #expect(WireGuardCommands.show(interface: "utun6", "latest-handshakes") == ["show", "utun6", "latest-handshakes"])
        #expect(WireGuardCommands.socketPath(interface: "utun6") == "/var/run/amneziawg/utun6.sock")
        #expect(WireGuardCommands.addAddress(v4, interface: "utun6") == ["utun6", "inet", "10.8.0.2/24", "10.8.0.2", "alias"])
        #expect(WireGuardCommands.addAddress(v6, interface: "utun6") == ["utun6", "inet6", "fd00:8::2/64", "alias"])
        #expect(WireGuardCommands.setMTU(1380, interface: "utun6") == ["utun6", "mtu", "1380"])
        #expect(WireGuardCommands.up(interface: "utun6") == ["utun6", "up"])
        #expect(WireGuardCommands.addRoute(v4.network, interface: "utun6") == ["-q", "-n", "add", "-inet", "10.8.0.0/24", "-interface", "utun6"])
        #expect(WireGuardCommands.addRoute(v6.network, interface: "utun6") == ["-q", "-n", "add", "-inet6", "fd00:8::/64", "-interface", "utun6"])
        #expect(WireGuardCommands.getRoute(v4.network) == ["-n", "get", "-inet", "10.8.0.0/24"])
        #expect(WireGuardCommands.deleteRoute(v6.network) == ["-q", "-n", "delete", "-inet6", "fd00:8::/64"])
        let peer = IPNetwork("203.0.113.5")!
        #expect(WireGuardCommands.addEndpointRoute(peer, gateway: "192.0.2.1") == ["-q", "-n", "add", "-inet", "203.0.113.5", "-gateway", "192.0.2.1"])
        #expect(WireGuardCommands.addEndpointRoute(peer, gateway: nil) == ["-q", "-n", "add", "-inet", "203.0.113.5", "127.0.0.1", "-blackhole"])
        #expect(WireGuardCommands.addEndpointRoute(IPNetwork("2001:db8::1")!, gateway: "fe80::1%en0") == ["-q", "-n", "add", "-inet6", "2001:db8::1", "-gateway", "fe80::1%en0"])
        #expect(WireGuardCommands.addEndpointRoute(IPNetwork("2001:db8::1")!, gateway: nil) == ["-q", "-n", "add", "-inet6", "2001:db8::1", "::1", "-blackhole"])
        #expect(WireGuardCommands.deleteEndpointRoute(peer) == ["-q", "-n", "delete", "-inet", "203.0.113.5"])
        #expect(WireGuardCommands.routingTable(ipv6: true) == ["-nr", "-f", "inet6"])
    }

    @Test func toolOutput() {
        #expect(AmneziaWGOutput.parse("ERROR: (utun6) 2026/11/24 10:00:00 Failed to create TUN device: operation not permitted") == .error("(utun6) 2026/11/24 10:00:00 Failed to create TUN device: operation not permitted"))
        #expect(AmneziaWGOutput.parse("DEBUG: (utun6) 2026/11/24 10:00:00 UAPI listener started") == nil)
        #expect(TunnelConfig.LogLevel.ofToolLine("DEBUG: (utun6) 2026/11/24 10:00:00 Device started") == .debug)
    }
}
