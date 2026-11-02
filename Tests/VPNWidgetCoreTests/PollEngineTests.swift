import Foundation
import Testing
@testable import VPNWidgetCore

@Suite struct PollEngineTests {
    @Test func pollsStateCheckTrafficAndUptime() async throws {
        let a = VPNProfile.test("a")
        let rig = Rig(profiles: [a], statuses: ["a": .connected])
        let since = rig.now.now.addingTimeInterval(-600)
        await rig.controller.setExtended("a", ExtendedStatus(lastChange: since, interfaceName: "utun7"))
        await rig.controller.setStats("a", Traffic(bytesIn: 10, bytesOut: 20))
        await rig.interfaces.setLink("a", LinkInfo(interfaceName: "utun5"))
        await rig.interfaces.setTakesOverDNS("a", true)

        let s = await rig.engine.poll()
        let p = try #require(s.profiles.first)
        #expect(p.state == .connected)
        #expect(p.checked)
        #expect(p.result == Rig.ok)
        #expect(p.traffic == Traffic(bytesIn: 10, bytesOut: 20))
        #expect(p.connectedSince == since)
        #expect(p.interfaceName == "utun5")
        #expect(p.takesOverDNS)
        #expect(!p.isPrimaryInterface)
        #expect(s.level == .ok)
    }

    @Test func downProfilesAreNotChecked() async throws {
        let a = VPNProfile.test("a")
        let rig = Rig(profiles: [a], statuses: ["a": .disconnected])
        let s = await rig.engine.poll()
        #expect(s.profiles[0].state == .disconnected)
        #expect(!s.profiles[0].checked)
        #expect(await rig.checker.calls == 0)
    }

    @Test func noCheckURLMeansNoCheckButTraffic() async throws {
        let a = VPNProfile.test("a", check: nil)
        let rig = Rig(profiles: [a], statuses: ["a": .connected])
        await rig.controller.setStats("a", Traffic(bytesIn: 1, bytesOut: 2))
        let s = await rig.engine.poll()
        #expect(!s.profiles[0].checked)
        #expect(s.profiles[0].traffic == Traffic(bytesIn: 1, bytesOut: 2))
        #expect(await rig.checker.calls == 0)
        #expect(s.level == .ok)
    }

    @Test func removedProfileIsNotFound() async throws {
        let a = VPNProfile.test("a")
        let rig = Rig(profiles: [a], statuses: ["a": .connected])
        await rig.directory.set([])
        let s = await rig.engine.poll()
        #expect(s.profiles[0].state == .notFound)
    }

    @Test func directoryErrorKeepsLastListing() async throws {
        let a = VPNProfile.test("a")
        let rig = Rig(profiles: [a], statuses: ["a": .connected])
        _ = await rig.engine.poll()
        await rig.directory.fail(ActionError("boom"))
        let s = await rig.engine.poll()
        #expect(s.profiles[0].state == .connected)
    }

    @Test func newTunnelFailingItsCheckIsConnectingUntilSettled() async throws {
        let a = VPNProfile.test("a")
        let rig = Rig(profiles: [a], statuses: ["a": .connected])
        await rig.checker.set(a.checkURL!.host!, Rig.down)
        await rig.controller.setExtended("a", ExtendedStatus(lastChange: rig.now.now.addingTimeInterval(-5)))

        var s = await rig.engine.poll()
        #expect(s.profiles[0].state == .connecting)
        #expect(!s.profiles[0].checked)
        #expect(s.level == .progress)

        // Still failing after the settle time: the failure counts, and the
        // grace has long passed because failures during settling counted.
        rig.now.advance(40)
        s = await rig.engine.poll()
        #expect(s.profiles[0].state == .connected)
        #expect(s.profiles[0].checked)
        #expect(s.profiles[0].result.failed)
        #expect(s.level == .problem)
    }

    @Test func settledTunnelFailureIsDoubtfulThenCounts() async throws {
        let a = VPNProfile.test("a")
        let rig = Rig(profiles: [a], statuses: ["a": .connected])
        await rig.controller.setExtended("a", ExtendedStatus(lastChange: rig.now.now.addingTimeInterval(-3600)))
        _ = await rig.engine.poll()
        await rig.checker.set(a.checkURL!.host!, Rig.down)

        var s = await rig.engine.poll()
        #expect(s.profiles[0].result.doubtful)
        #expect(s.doubtful)
        #expect(s.level == .ok)

        rig.now.advance(11)
        s = await rig.engine.poll()
        #expect(s.profiles[0].result.failed)
        #expect(s.level == .problem)

        // Down and up again: the failure count starts over.
        await rig.controller.set("a", .disconnected)
        _ = await rig.engine.poll()
        await rig.controller.set("a", .connected)
        s = await rig.engine.poll()
        #expect(s.profiles[0].result.doubtful)
    }

    @Test func uptimeFallsBackToFirstSeen() async throws {
        let a = VPNProfile.test("a", check: nil)
        let rig = Rig(profiles: [a], statuses: ["a": .connected])
        let first = rig.now.now
        var s = await rig.engine.poll()
        #expect(s.profiles[0].connectedSince == first)
        rig.now.advance(100)
        s = await rig.engine.poll()
        #expect(s.profiles[0].connectedSince == first)
    }

    @Test func transitionSinceIsKeptAcrossPolls() async throws {
        let a = VPNProfile.test("a")
        let rig = Rig(profiles: [a], statuses: ["a": .connecting])
        let t0 = rig.now.now
        _ = await rig.engine.poll()
        rig.now.advance(7)
        let s = await rig.engine.poll()
        #expect(s.profiles[0].transitionSince == t0)
    }

    @Test func actionsGoThroughHooksAndErrorsShow() async throws {
        let a = VPNProfile.test("a")
        let rig = Rig(profiles: [a], statuses: ["a": .disconnected]) { $0.repollAfter = [] }
        await rig.engine.perform(.connect, on: "a")
        #expect(await rig.controller.started == ["a"])

        await rig.controller.failStart(ActionError("refused by the system"))
        await rig.controller.set("a", .disconnected)
        await rig.engine.perform(.connect, on: "a")
        let s = await rig.engine.poll()
        #expect(s.profiles[0].lastActionError == "connect failed: refused by the system")

        await rig.controller.failStart(nil)
        await rig.engine.perform(.connect, on: "a")
        #expect(await rig.engine.poll().profiles[0].lastActionError == nil)
    }

    @Test func reconnectStopsThenStarts() async throws {
        let a = VPNProfile.test("a")
        let rig = Rig(profiles: [a], statuses: ["a": .connected]) { $0.repollAfter = []; $0.reconnectWait = .seconds(1) }
        await rig.engine.perform(.reconnect, on: "a")
        #expect(await rig.controller.stopped == ["a"])
        #expect(await rig.controller.started == ["a"])
    }

    @Test func connectAllSkipsConnectedAndAutoConnectHonoursFlag() async throws {
        var a = VPNProfile.test("a")
        var b = VPNProfile.test("b")
        let c = VPNProfile.test("c")
        a.autoConnect = true
        b.autoConnect = true
        let rig = Rig(profiles: [a, b, c], statuses: ["a": .disconnected, "b": .connected, "c": .disconnected]) { $0.repollAfter = [] }
        await rig.engine.autoConnect()
        #expect(await rig.controller.started == ["a"])

        await rig.controller.set("a", .disconnected)
        _ = await rig.engine.poll()
        await rig.engine.connectAll()
        #expect(Set(await rig.controller.started) == ["a", "c"])
    }

    @Test func runPublishesNotifiesAndRechecksQuickly() async throws {
        let a = VPNProfile.test("a")
        let rig = Rig(profiles: [a], statuses: ["a": .connected]) {
            $0.pollInterval = .seconds(10)
            $0.recheckInterval = .milliseconds(20)
            $0.repollAfter = []
        }
        await rig.controller.setExtended("a", ExtendedStatus(lastChange: rig.now.now.addingTimeInterval(-3600)))
        let stream = await rig.engine.snapshots()
        let runner = Task { await rig.engine.run() }
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.profiles[0].result.ok == true)
        #expect(await rig.notifier.notices.isEmpty)

        // A failure starts the fast recheck cadence: more polls arrive without a poke.
        await rig.checker.set(a.checkURL!.host!, Rig.down)
        await rig.engine.poke()
        let second = await iterator.next()
        #expect(second?.profiles[0].result.doubtful == true)
        let third = await iterator.next()
        #expect(third != nil)

        // Past the grace, the failure counts and is announced once.
        rig.now.advance(11)
        var announced = false
        for _ in 0..<10 {
            if let s = await iterator.next(), s.profiles[0].result.failed { announced = true; break }
        }
        #expect(announced)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await rig.notifier.notices == [Notice(summary: "A: connected, service not answering", body: "DNS ok · timeout")])
        runner.cancel()
    }

    @Test func setProfilesReplacesTheList() async throws {
        let a = VPNProfile.test("a")
        let b = VPNProfile.test("b")
        let rig = Rig(profiles: [a], statuses: ["a": .disconnected, "b": .disconnected])
        await rig.directory.set([a, b].map { DiscoveredService(id: $0.id, name: $0.displayName, enabled: true, providerBundleID: nil) })
        await rig.engine.setProfiles([b, a])
        let s = await rig.engine.poll()
        #expect(s.profiles.map(\.id) == ["b", "a"])
    }
}
