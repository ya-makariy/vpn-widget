import Foundation
import Testing
@testable import VPNWidgetCore

private func net(_ s: String) -> IPNetwork { IPNetwork(s)! }

/// netstat as it prints on macOS: A (openconnect) on utun6 holds
/// 192.168.77.0/24, B (AmneziaWG) on utun7 routes it too and lost it.
private let netstat = """
Routing tables

Internet:
Destination        Gateway            Flags               Netif Expire
default            192.0.2.1          UGScg                 en0
default            link#26            UCSIg                ppp0
192.168.77         192.168.77.229     UGSc                utun6
192.168.77         link#27            UScI                utun7
192.168.77.229     192.168.77.229     UH                  utun6
10.20/24           link#27            USc                 utun7
172.16             link#27            USc                 utun6
10.31.42/24        link#27            USc                 utun7
10.31.42.8         10.31.42.8         UH                  utun7
10.40/16           link#27            USc                 utun7
10.40.7.5/32       192.168.77.229     UGSc                utun6
100.96.8/21        link#26            USc                  ppp0
127                127.0.0.1          UCS                   lo0
192.0.2            link#14            UCS                   en0      !
192.0.2.1/32       link#14            UCS                   en0      !
198.51.100.7       192.0.2.1          UGHS                  en0
224.0.0/4          link#14            UmCS                  en0      !
"""

@Suite struct FakeIPTests {
    @Test func readsNetstatShorthand() {
        let routes = FakeIP.routes(inNetstat: netstat)
        let byText = Dictionary(routes.map { ("\($0.destination)|\($0.interface)|\($0.isScoped)", $0) }, uniquingKeysWith: { a, _ in a })
        #expect(byText["192.168.77.0/24|utun6|false"] != nil)
        #expect(byText["192.168.77.0/24|utun7|true"] != nil)
        #expect(byText["192.168.77.229/32|utun6|false"] != nil)
        #expect(byText["10.20.0.0/24|utun7|false"] != nil)
        #expect(byText["172.16.0.0/16|utun6|false"] != nil)
        #expect(byText["10.31.42.0/24|utun7|false"] != nil)
        #expect(byText["127.0.0.0/8|lo0|false"] != nil)
        #expect(byText["224.0.0.0/4|en0|false"] != nil)
        #expect(byText["198.51.100.7/32|en0|false"] != nil)
        #expect(!routes.contains { $0.gateway == "Gateway" })
        #expect(routes.allSatisfy { $0.destination.description != "0.0.0.0/0" })
    }

    @Test func tunnelInterfaces() {
        #expect(FakeIP.isTunnelInterface("utun7"))
        #expect(FakeIP.isTunnelInterface("ppp0"))
        #expect(FakeIP.isTunnelInterface("ipsec1"))
        #expect(!FakeIP.isTunnelInterface("utun"))
        #expect(!FakeIP.isTunnelInterface("en0"))
        #expect(!FakeIP.isTunnelInterface("lo0"))
        #expect(!FakeIP.isTunnelInterface("utunx"))
    }

    @Test func findsTheNetworkAnotherTunnelHolds() {
        let table = FakeIP.routes(inNetstat: netstat)
        let ours = [net("192.168.77.0/24"), net("10.20.0.0/24"), net("10.31.42.0/24"), net("10.40.0.0/16"), net("0.0.0.0/1")]
        let found = FakeIP.overlaps(of: ours, on: "utun7", in: table)
        // The /24 utun6 has (the host route of its own address is inside it),
        // and a host utun6 has inside our /16. Our own and scoped routes, and
        // routes by en0, are not overlaps; /1 is too wide to map.
        #expect(found == [
            FakeIP.Overlap(network: net("10.40.7.5/32"), interface: "utun6"),
            FakeIP.Overlap(network: net("192.168.77.0/24"), interface: "utun6"),
        ])
    }

    @Test func anotherTunnelsOwnAddressIsNoOverlap() {
        // B holds the /24 now; A's end of its link is a host route inside it.
        let table = FakeIP.routes(inNetstat: """
        192.168.77         link#25            USc                 utun6
        192.168.77.229     192.168.77.229     UH                  utun7
        192.168.77.40/32   192.168.77.229     UGSc                utun7
        """)
        #expect(table[1].isOwnAddress && !table[2].isOwnAddress && !table[0].isOwnAddress)
        #expect(FakeIP.overlaps(of: [net("192.168.77.0/24")], on: "utun6", in: table) == [FakeIP.Overlap(network: net("192.168.77.40/32"), interface: "utun7")])
    }

    @Test func aWiderRouteOfAnotherTunnelIsNoOverlap() {
        let table = [FakeIP.Route(destination: net("10.0.0.0/8"), gateway: "link#1", flags: "USc", interface: "utun3")]
        #expect(FakeIP.overlaps(of: [net("10.20.0.0/24")], on: "utun7", in: table).isEmpty)
        // Seen from the other side, ours is narrower and wins: utun3 has an overlap.
        let back = [FakeIP.Route(destination: net("10.20.0.0/24"), gateway: "link#2", flags: "USc", interface: "utun7")]
        #expect(FakeIP.overlaps(of: [net("10.0.0.0/8")], on: "utun3", in: back) == [FakeIP.Overlap(network: net("10.20.0.0/24"), interface: "utun7")])
        #expect(FakeIP.overlaps(of: [net("10.20.0.0/16")], on: "utun3", in: back) == [FakeIP.Overlap(network: net("10.20.0.0/24"), interface: "utun7")])
        #expect(FakeIP.overlaps(of: [net("0.0.0.0/1")], on: "utun3", in: back).isEmpty)
    }

    @Test func poolsStayClearOfOtherFakeIPRanges() {
        // Clash, sing-box and routers running them hand out 198.18.0.0/15.
        let theirs = net("198.18.0.0/15")
        #expect(FakeIP.pools.allSatisfy { !$0.overlaps(theirs) })
        #expect(FakeIP.inPools(net("198.51.100.7")))
        #expect(!FakeIP.inPools(net("198.18.0.171")))
    }

    @Test func allocatesAlignedBlocksAndSkipsTakenOnes() {
        #expect(FakeIP.allocate(for: net("10.20.0.0/24"), taken: []) == net("192.0.2.0/24"))
        #expect(FakeIP.allocate(for: net("10.20.0.0/24"), taken: [net("192.0.2.0/24")]) == net("198.51.100.0/24"))
        // A host taken in the first pool pushes a /24 to the next pool.
        #expect(FakeIP.allocate(for: net("10.20.0.0/24"), taken: [net("192.0.2.9/32")]) == net("198.51.100.0/24"))
        // Narrower networks share a pool, each aligned to its size.
        #expect(FakeIP.allocate(for: net("10.1.2.3/32"), taken: [net("192.0.2.0/25")]) == net("192.0.2.128/32"))
        #expect(FakeIP.allocate(for: net("10.1.2.0/26"), taken: [net("192.0.2.0/32")]) == net("192.0.2.64/26"))
        #expect(FakeIP.allocate(for: net("10.0.0.0/24"), taken: FakeIP.pools) == nil)
        #expect(FakeIP.allocate(for: net("10.0.0.0/23"), taken: []) == nil)
        #expect(FakeIP.allocate(for: net("fd00::/64"), taken: []) == nil)
    }

    @Test func tableKeepsMappingsStable() {
        var table = FakeIP.Table()
        let a = table.assign(tunnel: "b", real: net("10.20.0.7/24"))
        #expect(a?.real == "10.20.0.0/24")
        #expect(a?.fake == "192.0.2.0/24")
        let other = table.assign(tunnel: "c", real: net("10.20.0.0/24"))
        #expect(other?.fake == "198.51.100.0/24")
        #expect(table.assign(tunnel: "b", real: net("10.20.0.0/24")) == a)
        #expect(table.assign(tunnel: "b", real: net("10.30.0.0/24"), avoid: [net("203.0.113.0/24")]) == nil)
        let avoided = table.assign(tunnel: "b", real: net("10.30.0.0/28"), avoid: [net("203.0.113.0/25")])
        #expect(avoided?.fake == "203.0.113.128/28")
        table.remove(tunnel: "b")
        #expect(table.mappings.map(\.tunnel) == ["c"])
        let data = try! JSONEncoder().encode(table)
        #expect(try! JSONDecoder().decode(FakeIP.Table.self, from: data) == table)
    }

    @Test func rangesOutsideThePoolsAreGivenUp() {
        var table = FakeIP.Table(mappings: [FakeIP.Mapping(tunnel: "b", real: net("10.20.0.0/24"), fake: net("198.18.0.0/24"))])
        #expect(table.assign(tunnel: "b", real: net("10.20.0.0/24"))?.fake == "192.0.2.0/24")
        #expect(table.mappings.count == 1)
    }

    @Test func tableKeepsChoicesAndReadsOldFiles() {
        var table = FakeIP.Table()
        table.setOwner("b", of: net("10.20.0.9/24"))
        #expect(table.owner(of: net("10.20.0.0/24")) == "b")
        #expect(table.owners == ["10.20.0.0/24": "b"])
        _ = table.assign(tunnel: "b", real: net("10.30.0.0/24"))
        table.remove(tunnel: "b")
        #expect(table.owners.isEmpty && table.mappings.isEmpty)
        let old = #"{"mappings":[{"tunnel":"b","real":"10.20.0.0/24","fake":"192.0.2.0/24"}]}"#
        let decoded = try! JSONDecoder().decode(FakeIP.Table.self, from: Data(old.utf8))
        #expect(decoded.mappings.count == 1 && decoded.owners.isEmpty)
        table.setOwner(nil, of: net("10.20.0.0/24"))
        #expect(table.owners.isEmpty)
    }

    @Test func routeActionsFollowTheChoice() {
        let table = [
            FakeIP.Route(destination: net("10.20.0.0/24"), gateway: "10.20.0.229", flags: "UGSc", interface: "utun6"),
            FakeIP.Route(destination: net("10.20.0.0/24"), gateway: "link#27", flags: "UScI", interface: "utun7"),
            FakeIP.Route(destination: net("10.31.42.0/24"), gateway: "link#27", flags: "USc", interface: "utun7"),
            FakeIP.Route(destination: net("10.50.0.0/24"), gateway: "192.0.2.1", flags: "UGSc", interface: "en0"),
        ]
        let wanted = [net("10.20.0.0/24"), net("10.31.42.0/24"), net("10.40.0.0/24"), net("10.50.0.0/24"), net("0.0.0.0/1")]
        // Not chosen: the free network is added, the held one left alone.
        #expect(FakeIP.routeActions(wanted: wanted, me: "b", interface: "utun7", table: table, owners: [:]) == [.add(net("10.40.0.0/24"))])
        #expect(FakeIP.routeActions(wanted: wanted, me: "b", interface: "utun7", table: table, owners: ["10.20.0.0/24": "a"]) == [.add(net("10.40.0.0/24"))])
        // Chosen: taken from the other tunnel; a route by en0 never is.
        #expect(FakeIP.routeActions(wanted: wanted, me: "b", interface: "utun7", table: table, owners: ["10.20.0.0/24": "b", "10.50.0.0/24": "b"]) == [
            .take(net("10.20.0.0/24"), from: "utun6"), .add(net("10.40.0.0/24")),
        ])
        // The holder keeps what it has, chosen or not.
        #expect(FakeIP.routeActions(wanted: [net("10.20.0.0/24")], me: "a", interface: "utun6", table: table, owners: ["10.20.0.0/24": "b"]).isEmpty)
    }

    @Test func networksOnAnInterface() {
        let table = FakeIP.routes(inNetstat: netstat)
        // Its own address and the scoped route of another interface are left out.
        #expect(Set(FakeIP.networks(on: "utun6", in: table, ownAddress: "192.168.77.229")) == [net("192.168.77.0/24"), net("172.16.0.0/16"), net("10.40.7.5/32")])
        #expect(!FakeIP.networks(on: "utun7", in: table, ownAddress: "10.31.42.8").contains(net("192.168.77.0/24")))
    }

    @Test func sharedNetworksFromStateFiles() {
        func state(_ interface: String, _ fakes: [TunnelState.FakeNetwork], supports: Bool? = true) -> TunnelState {
            TunnelState(phase: .connected, since: Date(), interfaceName: interface, fakeNetworks: fakes, supportsStandIns: supports)
        }
        var states = [
            "a": state("utun6", [], supports: nil),
            "b": state("utun7", [.init(real: "10.20.0.0/24", fake: "192.0.2.0/24", sharedWith: "utun6")]),
            "c": state("utun8", [.init(real: "10.20.0.0/24", fake: "198.51.100.0/24", sharedWith: "utun6"), .init(real: "10.60.0.0/24", fake: "203.0.113.0/24", sharedWith: "")]),
            "d": state("ppp0", [.init(real: "10.70.0.0/24", fake: "203.0.113.0/25", sharedWith: "utun3")]),
        ]
        let shared = FakeIP.sharedNetworks(states: states, owners: ["10.20.0.0/24": "a"])
        #expect(shared.map(\.network) == ["10.20.0.0/24", "10.70.0.0/24"])
        #expect(shared[0].holder == "a")
        #expect(shared[0].chosen == "a")
        #expect(shared[0].members == [
            .init(tunnel: "a", fake: nil, canShare: false),
            .init(tunnel: "b", fake: "192.0.2.0/24", canShare: true),
            .init(tunnel: "c", fake: "198.51.100.0/24", canShare: true),
        ])
        // Held by an interface that is not one of ours: no holder, one member.
        #expect(shared[1].holder == nil)
        #expect(shared[1].members.map(\.tunnel) == ["d"])
        // After a switch the former holder has a stand-in, the new one keeps its own.
        states["a"] = state("utun6", [.init(real: "10.20.0.0/24", fake: "203.0.113.0/24", sharedWith: "utun7")])
        states["b"] = state("utun7", [.init(real: "10.20.0.0/24", fake: "192.0.2.0/24", sharedWith: "")])
        states["c"] = state("utun8", [.init(real: "10.20.0.0/24", fake: "198.51.100.0/24", sharedWith: "utun7")])
        let switched = FakeIP.sharedNetworks(states: states, owners: ["10.20.0.0/24": "b"])
        #expect(switched[0].holder == "b")
        #expect(switched[0].members.map(\.tunnel) == ["a", "b", "c"])
        #expect(switched[0].members.map(\.fake) == ["203.0.113.0/24", "192.0.2.0/24", "198.51.100.0/24"])
        // Tunnels that are not connected do not count.
        states["c"]?.phase = .stopped
        #expect(FakeIP.sharedNetworks(states: states, owners: [:])[0].members.map(\.tunnel) == ["a", "b"])
    }

    @Test func translatesBothWays() {
        let m = FakeIP.Mapping(tunnel: "b", real: net("10.20.0.0/24"), fake: net("192.0.2.0/24"))
        #expect(m.fake(for: net("10.20.0.20"))?.address == "192.0.2.20")
        #expect(m.real(for: net("192.0.2.20"))?.address == "10.20.0.20")
        #expect(m.fake(for: net("10.21.0.20")) == nil)
        #expect(m.real(for: net("198.51.100.20")) == nil)
        let host = FakeIP.Mapping(tunnel: "b", real: net("10.40.7.5/32"), fake: net("192.0.2.3/32"))
        #expect(host.fake(for: net("10.40.7.5"))?.address == "192.0.2.3")
        #expect(host.real(for: net("192.0.2.3"))?.address == "10.40.7.5")
    }

    @Test func anchorNamesAreSafe() {
        #expect(FakeIP.anchor(tunnel: "office-2") == "com.apple/vpn-widget.office-2")
        // A Cyrillic р is spelled out, never passed to pfctl as is.
        #expect(FakeIP.anchor(tunnel: "\u{0440}office") == "com.apple/vpn-widget.d1806f6666696365")
    }

    @Test func pfRulesTranslationFirst() {
        let rules = FakeIP.pfRules(fakes: [net("192.0.2.0/24"), net("198.51.100.3/32"), net("fd00::/64")], port: 40123)
        #expect(rules == """
        rdr pass on lo0 inet proto tcp from any to 192.0.2.0/24 -> 127.0.0.1 port 40123
        rdr pass on lo0 inet proto tcp from any to 198.51.100.3/32 -> 127.0.0.1 port 40123
        pass out quick route-to lo0 inet proto tcp from any to 192.0.2.0/24 keep state
        pass out quick route-to lo0 inet proto tcp from any to 198.51.100.3/32 keep state

        """)
        #expect(FakeIP.pfRules(fakes: [], port: 1) == "")
    }

    @Test func scopedRouteCommandsPutIfscopeFirst() {
        #expect(FakeIP.addScopedRoute(net("10.20.0.9/24"), interface: "utun7") == ["-q", "-n", "add", "-net", "-ifscope", "utun7", "10.20.0.0/24", "-interface", "utun7"])
        #expect(FakeIP.deleteScopedRoute(net("10.20.0.0/24"), interface: "utun7") == ["-q", "-n", "delete", "-net", "-ifscope", "utun7", "10.20.0.0/24", "-interface", "utun7"])
    }

    @Test func natLookLayout() {
        #expect(NatLook.request == 0xC054_4417)
        let request = NatLook.encode(client: [127, 0, 0, 1], clientPort: 50000, local: [127, 0, 0, 1], localPort: 40123)
        #expect(request.count == 84)
        #expect(Array(request[0..<4]) == [127, 0, 0, 1])
        #expect(Array(request[16..<20]) == [127, 0, 0, 1])
        #expect(Array(request[64..<66]) == [0xC3, 0x50])
        #expect(Array(request[68..<70]) == [0x9C, 0xBB])
        #expect(Array(request[80..<84]) == [2, 6, 0, 2])
        var answer = request
        answer.replaceSubrange(48..<52, with: [192, 0, 2, 20])
        answer.replaceSubrange(76..<78, with: [0x01, 0xBB])
        let destination = NatLook.destination(in: answer)
        #expect(destination?.address == [192, 0, 2, 20])
        #expect(destination?.port == 443)
        #expect(NatLook.destination(in: request) == nil)
    }
}

@Suite struct DNSRewriteTests {
    /// wiki.b.example A? → two A records, a CNAME before them, an OPT after.
    static let response: [UInt8] = {
        var m: [UInt8] = [0x12, 0x34, 0x81, 0x80, 0, 1, 0, 3, 0, 0, 0, 1]
        let name: [UInt8] = [4] + Array("wiki".utf8) + [1] + Array("b".utf8) + [7] + Array("example".utf8) + [0]
        m += name + [0, 1, 0, 1]
        // CNAME wiki → web.b.example (pointer to "b.example" at offset 17)
        let target: [UInt8] = [3] + Array("web".utf8) + [0xC0, 17]
        m += [0xC0, 12, 0, 5, 0, 1, 0, 0, 0, 60, 0, UInt8(target.count)] + target
        m += [0xC0, 12, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 10, 20, 0, 20]
        m += [0xC0, 12, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 203, 0, 113, 5]
        m += [0, 0, 41, 4, 0xD0, 0, 0, 0, 0, 0, 0]
        return m
    }()

    @Test func rewritesOnlyMappedARecords() {
        let m = FakeIP.Mapping(tunnel: "b", real: IPNetwork("10.20.0.0/24")!, fake: IPNetwork("192.0.2.0/24")!)
        let out = DNSRewrite.rewriteA(Self.response) { bytes in
            m.fake(for: IPNetwork(bytes: bytes, prefix: 32)).map(\.bytes)
        }
        #expect(out.count == Self.response.count)
        var expected = Self.response
        let at = expected.indices.first { Array(expected[$0..<$0 + 4]) == [10, 20, 0, 20] }!
        expected.replaceSubrange(at..<at + 4, with: [192, 0, 2, 20])
        #expect(out == expected)
        #expect(DNSRewrite.id(out) == 0x1234)
    }

    @Test func capsTheTTLOfRewrittenRecordsOnly() {
        var original = Self.response
        // TTL 3600 on both A records.
        for i in original.indices.dropLast(10) where Array(original[i..<i + 10]) == [0xC0, 12, 0, 1, 0, 1, 0, 0, 0, 60] {
            original[i + 8] = 0x0E; original[i + 9] = 0x10
        }
        let out = DNSRewrite.rewriteA(original, ttlCap: 30) { $0 == [10, 20, 0, 20] ? [192, 0, 2, 20] : nil }
        let ttls = out.indices.dropLast(12).filter { Array(out[$0..<$0 + 6]) == [0xC0, 12, 0, 1, 0, 1] }.map { Array(out[$0 + 6..<$0 + 10]) }
        #expect(ttls == [[0, 0, 0, 30], [0, 0, 0x0E, 0x10]])
    }

    @Test func leavesBrokenMessagesAlone() {
        let truncated = Array(Self.response.prefix(40))
        #expect(DNSRewrite.rewriteA(truncated) { _ in [1, 2, 3, 4] } == truncated)
        #expect(DNSRewrite.rewriteA([1, 2, 3]) { _ in [1, 2, 3, 4] } == [1, 2, 3])
        var loop = Self.response
        loop[12] = 0xC0
        loop[13] = 12
        #expect(DNSRewrite.rewriteA(loop) { _ in [1, 2, 3, 4] }.count == loop.count)
    }
}
