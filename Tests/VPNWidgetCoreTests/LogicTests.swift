import Foundation
import Testing
@testable import VPNWidgetCore

@Suite struct FailureTrackerTests {
    @Test func failureIsDoubtfulUntilGracePasses() {
        var t = FailureTracker(failGrace: 10)
        let t0 = Date(timeIntervalSince1970: 1000)
        let fail = CheckResult(dns: "ok", http: "timeout")
        #expect(t.confirm(key: "a", result: fail, now: t0).doubtful)
        #expect(t.confirm(key: "a", result: fail, now: t0.addingTimeInterval(10)).doubtful)
        #expect(!t.confirm(key: "a", result: fail, now: t0.addingTimeInterval(10.5)).doubtful)
    }

    @Test func successResetsAndForgetDrops() {
        var t = FailureTracker(failGrace: 10)
        let t0 = Date(timeIntervalSince1970: 1000)
        let fail = CheckResult(http: "timeout")
        _ = t.confirm(key: "a", result: fail, now: t0)
        _ = t.confirm(key: "a", result: Rig.ok, now: t0.addingTimeInterval(20))
        #expect(t.confirm(key: "a", result: fail, now: t0.addingTimeInterval(21)).doubtful)
        t.forget(key: "a")
        #expect(t.confirm(key: "a", result: fail, now: t0.addingTimeInterval(60)).doubtful)
    }

    @Test func keysAreIndependent() {
        var t = FailureTracker(failGrace: 10)
        let t0 = Date(timeIntervalSince1970: 1000)
        let fail = CheckResult(http: "timeout")
        _ = t.confirm(key: "a", result: fail, now: t0)
        #expect(t.confirm(key: "b", result: fail, now: t0.addingTimeInterval(30)).doubtful)
        #expect(!t.confirm(key: "a", result: fail, now: t0.addingTimeInterval(30)).doubtful)
    }
}

@Suite struct ChangeTrackerTests {
    let a = VPNProfile.test("a")
    let b = VPNProfile.test("b")

    func snap(_ states: [ProfileState]) -> Snapshot { Snapshot(profiles: states, at: Date()) }

    @Test func firstSnapshotIsSilent() {
        var t = ChangeTracker()
        #expect(t.next(snap([ProfileState(profile: a, state: .connected)])).isEmpty)
    }

    @Test func statusChangeNotifies() {
        var t = ChangeTracker()
        _ = t.next(snap([ProfileState(profile: a, state: .disconnected), ProfileState(profile: b, state: .disconnected)]))
        let notices = t.next(snap([ProfileState(profile: a, state: .connected), ProfileState(profile: b, state: .disconnected)]))
        #expect(notices == [Notice(summary: "A: connected")])
    }

    @Test func checkFailureNotifiesOnceAndDoubtfulDoesNot() {
        var t = ChangeTracker()
        let up = ProfileState(profile: a, state: .connected, checked: true, result: Rig.ok)
        _ = t.next(snap([up]))
        let doubtful = ProfileState(profile: a, state: .connected, checked: true, result: CheckResult(dns: "ok", http: "timeout", doubtful: true))
        #expect(t.next(snap([doubtful])).isEmpty)
        let failed = ProfileState(profile: a, state: .connected, checked: true, result: CheckResult(dns: "ok", http: "timeout"))
        #expect(t.next(snap([failed])) == [Notice(summary: "A: connected, service not answering", body: "DNS ok · timeout")])
        #expect(t.next(snap([failed])).isEmpty)
        #expect(t.next(snap([up])) == [Notice(summary: "A: connected", body: "DNS ok · HTTP 200 · latency 5 ms · total 20 ms")])
    }

    @Test func latencyChangesAreSilent() {
        var t = ChangeTracker()
        _ = t.next(snap([ProfileState(profile: a, state: .connected, checked: true, result: Rig.ok)]))
        var slower = Rig.ok
        slower.connectMS = 500
        #expect(t.next(snap([ProfileState(profile: a, state: .connected, checked: true, result: slower, traffic: Traffic(bytesIn: 1, bytesOut: 1))])).isEmpty)
    }

    @Test func newProfilesAreSilentUntilTheyChange() {
        var t = ChangeTracker()
        _ = t.next(snap([ProfileState(profile: a, state: .connected)]))
        #expect(t.next(snap([ProfileState(profile: a, state: .connected), ProfileState(profile: b, state: .connected)])).isEmpty)
        #expect(t.next(snap([ProfileState(profile: b, state: .disconnected)])) == [Notice(summary: "B: disconnected")])
    }
}

@Suite struct LevelTests {
    let a = VPNProfile.test("a")
    let b = VPNProfile.test("b")
    func level(_ states: [ProfileState]) -> IconLevel { Snapshot(profiles: states, at: Date()).level }

    @Test func table() {
        #expect(level([]) == .off)
        #expect(level([ProfileState(profile: a, state: .disconnected)]) == .off)
        #expect(level([ProfileState(profile: a, state: .connected, checked: true, result: Rig.ok)]) == .ok)
        #expect(level([ProfileState(profile: a, state: .connected), ProfileState(profile: b, state: .disconnected)]) == .partial)
        #expect(level([ProfileState(profile: a, state: .connecting), ProfileState(profile: b, state: .disconnected)]) == .progress)
        #expect(level([ProfileState(profile: a, state: .disconnecting), ProfileState(profile: b, state: .connected)]) == .progress)
        #expect(level([ProfileState(profile: a, state: .connected, checked: true, result: CheckResult(http: "timeout"))]) == .problem)
        #expect(level([ProfileState(profile: a, state: .connected, checked: true, result: CheckResult(http: "timeout", doubtful: true))]) == .ok)
        #expect(level([ProfileState(profile: a, state: .invalid), ProfileState(profile: b, state: .connecting)]) == .problem)
        #expect(level([ProfileState(profile: a, state: .notFound), ProfileState(profile: b, state: .connected)]) == .partial)
    }

    @Test func doubtful() {
        #expect(Snapshot(profiles: [ProfileState(profile: a, state: .connected, checked: true, result: CheckResult(http: "timeout", doubtful: true))], at: Date()).doubtful)
        #expect(!Snapshot(profiles: [ProfileState(profile: a, state: .connected, checked: false, result: CheckResult(http: "timeout", doubtful: true))], at: Date()).doubtful)
    }
}

@Suite struct ResolverFilesTests {
    @Test func normalizesDomains() {
        #expect(ResolverFiles.normalizeDomain(" Corp.Example. ") == "corp.example")
        #expect(ResolverFiles.normalizeDomain("") == nil)
        #expect(ResolverFiles.normalizeDomain("a/b") == nil)
        #expect(ResolverFiles.normalizeDomain("bad domain") == nil)
        #expect(ResolverFiles.normalizeDomain("..") == nil)
    }

    @Test func recognisesServers() {
        #expect(ResolverFiles.isServer("10.0.0.1"))
        #expect(ResolverFiles.isServer("fd00::1"))
        #expect(!ResolverFiles.isServer("dns.example"))
        #expect(!ResolverFiles.isServer("10.0.0"))
    }

    @Test func rendersMergedFiles() {
        let a = VPNProfile(id: "a", displayName: "A", providerKind: .forticlient, dnsDomains: ["corp.example", "Lab.Example"], dnsServers: ["10.0.0.1", "10.0.0.2"])
        let b = VPNProfile(id: "b", displayName: "B", providerKind: .amneziawg, dnsDomains: ["lab.example"], dnsServers: ["10.9.9.9", "10.0.0.1", "not-an-ip"])
        let none = VPNProfile(id: "c", displayName: "C", providerKind: .wireguard, dnsDomains: ["x.example"], dnsServers: [])
        let files = ResolverFiles.render(profiles: [a, b, none])
        #expect(files.keys.sorted() == ["corp.example", "lab.example"])
        #expect(files["corp.example"] == "# Managed by VPN Widget\nnameserver 10.0.0.1\nnameserver 10.0.0.2\n")
        #expect(files["lab.example"] == "# Managed by VPN Widget\nnameserver 10.0.0.1\nnameserver 10.0.0.2\nnameserver 10.9.9.9\n")
    }

    @Test func status() {
        let mine = "# Managed by VPN Widget\nnameserver 10.0.0.1\n"
        #expect(ResolverFiles.status(expected: mine, actual: mine) == .installed)
        #expect(ResolverFiles.status(expected: mine, actual: "# Managed by VPN Widget\nnameserver 10.0.0.2\n") == .outOfDate)
        #expect(ResolverFiles.status(expected: mine, actual: nil) == .notInstalled)
        #expect(ResolverFiles.status(expected: mine, actual: "nameserver 1.1.1.1\n") == .foreign)
        #expect(ResolverFiles.status(expected: nil, actual: mine) == .outOfDate)
        #expect(ResolverFiles.status(expected: nil, actual: nil) == .notInstalled)
    }

    @Test func scriptInstallsAndRemovesOnlyManagedFiles() {
        let script = ResolverFiles.applyScript(stageDirectory: "/tmp/stage it's", install: ["corp.example"], remove: ["old.example"])
        #expect(script.hasPrefix("set -e\n"))
        #expect(script.contains("/usr/bin/install -d -m 755 -o root -g wheel '/etc/resolver'"))
        #expect(script.contains("if [ -f '/etc/resolver/old.example' ] && /usr/bin/grep -q '# Managed by VPN Widget' '/etc/resolver/old.example'; then /bin/rm -f '/etc/resolver/old.example'; fi"))
        #expect(script.contains("/usr/bin/install -m 644 -o root -g wheel '/tmp/stage it'\\''s/corp.example' '/etc/resolver/corp.example'"))
        #expect(script.contains("refusing to overwrite /etc/resolver/corp.example"))
    }

    @Test func shellQuote() {
        #expect(ResolverFiles.shellQuote("plain") == "'plain'")
        #expect(ResolverFiles.shellQuote("it's") == "'it'\\''s'")
    }
}

@Suite struct ReachabilityMappingTests {
    typealias R = ReachabilityCheckerURLSession

    @Test func describesErrors() {
        #expect(R.describe(URLError(.cannotFindHost)) == "no such host")
        #expect(R.describe(URLError(.dnsLookupFailed)) == "lookup failed")
        #expect(R.describe(URLError(.timedOut)) == "timeout")
        #expect(R.describe(URLError(.cannotConnectToHost)) == "refused")
        #expect(R.describe(URLError(.networkConnectionLost)) == "connection reset")
        #expect(R.describe(URLError(.notConnectedToInternet)) == "unreachable")
        #expect(R.describe(URLError(.serverCertificateUntrusted)) == "bad certificate")
        #expect(R.describe(URLError(.secureConnectionFailed)) == "bad certificate")
        #expect(R.describe(URLError(.badServerResponse)) == "failed")
    }

    @Test func unreachableFromPosixCode() {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(EHOSTUNREACH))
        let error = URLError(.cannotConnectToHost, userInfo: [NSUnderlyingErrorKey: posix])
        #expect(R.describe(error) == "unreachable")
    }

    @Test func resultFromStatus() {
        let r = R.result(from: R.Outcome(status: 401, dnsMS: 3, connectMS: 12, totalMS: 90, resolved: true), hostIsLiteral: false)
        #expect(r == CheckResult(dns: "ok", http: "HTTP 401", dnsMS: 3, connectMS: 12, totalMS: 90, httpStatus: 401, ok: true))
        #expect(!R.result(from: R.Outcome(status: 502), hostIsLiteral: false).ok)
        #expect(R.result(from: R.Outcome(status: 302), hostIsLiteral: false).ok)
    }

    @Test func resultFromErrors() {
        let dns = R.result(from: R.Outcome(error: URLError(.cannotFindHost), dnsMS: 40), hostIsLiteral: false)
        #expect(dns == CheckResult(dns: "no such host", dnsMS: 40))
        let timeout = R.result(from: R.Outcome(error: URLError(.timedOut), dnsMS: 2, resolved: true), hostIsLiteral: false)
        #expect(timeout.dns == "ok")
        #expect(timeout.http == "timeout")
        #expect(!timeout.ok)
        let literal = R.result(from: R.Outcome(error: URLError(.cannotConnectToHost)), hostIsLiteral: true)
        #expect(literal.dns == "ok")
        #expect(literal.http == "refused")
        let unknown = R.result(from: R.Outcome(error: URLError(.timedOut)), hostIsLiteral: false)
        #expect(unknown.dns == "")
    }
}
