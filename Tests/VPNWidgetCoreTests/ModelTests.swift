import Foundation
import Testing
@testable import VPNWidgetCore

@Suite struct ProviderKindTests {
    @Test func mapsKnownProviders() {
        #expect(ProviderKind(bundleID: "com.fortinet.forticlient.macos.vpn.nwextension") == .forticlient)
        #expect(ProviderKind(bundleID: "com.cisco.anyconnect.networkextension") == .anyconnect)
        #expect(ProviderKind(bundleID: "org.amnezia.awg.network-extension") == .amneziawg)
        #expect(ProviderKind(bundleID: "com.wireguard.macos.network-extension") == .wireguard)
    }

    @Test func unknownIsOther() {
        #expect(ProviderKind(bundleID: "io.nekohasekai.sfamt.system") == .other)
        #expect(ProviderKind(bundleID: nil) == .other)
    }
}

@Suite struct StateTests {
    @Test func derivesFromStatusAndDirectory() {
        #expect(deriveState(raw: .connected, inDirectory: true) == .connected)
        #expect(deriveState(raw: .connecting, inDirectory: true) == .connecting)
        #expect(deriveState(raw: .disconnecting, inDirectory: true) == .disconnecting)
        #expect(deriveState(raw: .disconnected, inDirectory: true) == .disconnected)
        #expect(deriveState(raw: .invalid, inDirectory: true) == .invalid)
        #expect(deriveState(raw: nil, inDirectory: true) == .invalid)
        #expect(deriveState(raw: .connected, inDirectory: false) == .notFound)
    }

    @Test func actions() {
        #expect(ConnectionState.disconnected.actions == Actions(connect: true))
        #expect(ConnectionState.invalid.actions == Actions(connect: true))
        #expect(ConnectionState.connected.actions == Actions(disconnect: true, reconnect: true))
        #expect(ConnectionState.connecting.actions == Actions(disconnect: true, reconnect: true))
        #expect(ConnectionState.disconnecting.actions == Actions())
        #expect(ConnectionState.notFound.actions == Actions())
    }
}

@Suite struct FormattingTests {
    @Test func bytes() {
        #expect(formatBytes(0) == "0 B")
        #expect(formatBytes(1023) == "1023 B")
        #expect(formatBytes(1024) == "1.0 KiB")
        #expect(formatBytes(1_536) == "1.5 KiB")
        #expect(formatBytes(5 * 1024 * 1024) == "5.0 MiB")
        #expect(formatBytes(3 * 1024 * 1024 * 1024) == "3.0 GiB")
    }

    @Test func uptime() {
        #expect(formatUptime(5) == "5s")
        #expect(formatUptime(125) == "2m")
        #expect(formatUptime(3 * 3600 + 7 * 60) == "3h 7m")
        #expect(formatUptime(2 * 86400 + 5 * 3600) == "2d 5h")
        #expect(formatUptime(-3) == "0s")
    }

    @Test func checkDescription() {
        #expect(CheckResult(dns: "ok", http: "HTTP 401", connectMS: 12, totalMS: 80, ok: true).description == "DNS ok · HTTP 401 · latency 12 ms · total 80 ms")
        #expect(CheckResult(dns: "no such host").description == "DNS no such host")
        #expect(CheckResult(dns: "ok", http: "timeout", doubtful: true).description == "DNS ok · timeout · rechecking")
        #expect(CheckResult(http: "HTTP 503").failed)
        #expect(!CheckResult(http: "HTTP 503", doubtful: true).failed)
    }

    @Test func statusText() {
        let p = VPNProfile.test("a")
        #expect(ProfileState(profile: p, state: .connected).statusText == "connected")
        #expect(ProfileState(profile: p, state: .connected, checked: true, result: CheckResult(http: "timeout")).statusText == "connected, service not answering")
        #expect(ProfileState(profile: p, state: .connected, checked: true, result: CheckResult(http: "timeout", doubtful: true)).statusText == "connected")
    }

    @Test func linkLine() {
        let p = VPNProfile.test("a")
        let now = Date()
        var s = ProfileState(profile: p, state: .connected, traffic: Traffic(bytesIn: 2048, bytesOut: 10), connectedSince: now.addingTimeInterval(-90))
        #expect(s.linkLine(now: now) == "received 2.0 KiB · sent 10 B · up 1m")
        s.traffic = nil
        #expect(s.linkLine(now: now) == "up 1m")
        s.connectedSince = nil
        #expect(s.linkLine(now: now) == "")
    }
}

@Suite struct ProfileCodingTests {
    @Test func missingKeysTakeDefaults() throws {
        let json = #"{"profiles":[{"id":"X"}]}"#.data(using: .utf8)!
        let config = try JSONDecoder().decode(StoredConfig.self, from: json)
        #expect(config.version == StoredConfig.currentVersion)
        #expect(config.profiles.count == 1)
        #expect(config.profiles[0].displayName == "X")
        #expect(config.profiles[0].providerKind == .other)
        #expect(config.profiles[0].checkURL == nil)
        #expect(config.managedResolverDomains.isEmpty)
    }

    @Test func roundTrip() throws {
        let store = ProfileStoreJSON(url: FileManager.default.temporaryDirectory.appendingPathComponent("vpnw-\(UUID().uuidString)/profiles.json"))
        #expect(try store.load() == StoredConfig())
        let config = StoredConfig(profiles: [VPNProfile(id: "A", displayName: "Alpha", providerKind: .forticlient, checkURL: URL(string: "https://a.example/"), insecureTLS: true, autoConnect: true, dnsDomains: ["a.example"], dnsServers: ["10.0.0.1"])], managedResolverDomains: ["a.example"])
        try store.save(config)
        #expect(try store.load() == config)
        try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent())
    }
}
