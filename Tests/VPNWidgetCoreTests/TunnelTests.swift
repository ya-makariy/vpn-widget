import Foundation
import Testing
@testable import VPNWidgetCore

@Suite struct TunnelConfigTests {
    @Test func names() {
        #expect(TunnelConfig.isValidName("corp-sso"))
        #expect(TunnelConfig.isValidName("a1"))
        #expect(!TunnelConfig.isValidName(""))
        #expect(!TunnelConfig.isValidName("Corp"))
        #expect(!TunnelConfig.isValidName("-x"))
        #expect(!TunnelConfig.isValidName("a b"))
        #expect(!TunnelConfig.isValidName("a/b"))
        #expect(TunnelConfig.suggestName(from: "Corp Cloud SSO!") == "corp-cloud-sso")
        #expect(TunnelConfig.suggestName(from: "  --  ") == "")
    }

    @Test func namesAreASCII() {
        // U+0440, the Cyrillic letter that looks like a Latin p.
        let lookalike = "\u{0440}rod"
        #expect(TunnelConfig.isValidName("prod"))
        #expect(!TunnelConfig.isValidName(lookalike))
        #expect(!TunnelConfig.isValidName("caf\u{00E9}"))
        // Arabic-Indic digits are decimal digits too.
        #expect(!TunnelConfig.isValidName("a\u{0661}"))
        #expect(TunnelConfig.isValidName(String(repeating: "a", count: 40)))
        #expect(!TunnelConfig.isValidName(String(repeating: "a", count: 41)))
    }

    @Test func installedNamesStayAddressable() {
        #expect(TunnelConfig.isInstalledName("corp-sso"))
        #expect(TunnelConfig.isInstalledName("\u{0440}rod"))
        #expect(TunnelConfig.isInstalledName("caf\u{00E9}"))
    }

    @Test func unsafeNamesAreRejectedByBothChecks() {
        let unsafe = ["", "a/b", "../x", "a.b", ".", "a b", "a\tb", "a\nb", "-x", "x-", "Corp", "a;b", "a$b", "a\u{0}b", "\u{0440}/x", "a\u{00A0}b", "a\u{0301}", String(repeating: "\u{0440}", count: 41)]
        for name in unsafe {
            #expect(!TunnelConfig.isValidName(name), "strict: \(name.debugDescription)")
            #expect(!TunnelConfig.isInstalledName(name), "installed: \(name.debugDescription)")
        }
    }

    @Test func suggestedNamesAreASCII() {
        #expect(TunnelConfig.suggestName(from: "\u{0420}rod VPN") == "rod-vpn")
        #expect(TunnelConfig.suggestName(from: "Caf\u{00E9} 2") == "caf-2")
        #expect(TunnelConfig.suggestName(from: "\u{043F}\u{0440}\u{043E}\u{0434}") == "")
        #expect(TunnelConfig.suggestName(from: "Lab \u{0661}\u{0662}") == "lab")
        for title in ["\u{0420}rod VPN", "Caf\u{00E9} 2", "\u{00DF}\u{0131}x", "Stra\u{00DF}e-9", String(repeating: "\u{0440}a", count: 60)] {
            let name = TunnelConfig.suggestName(from: title)
            #expect(name.unicodeScalars.allSatisfy { $0.isASCII })
            #expect(name.isEmpty || TunnelConfig.isValidName(name))
        }
    }

    @Test func profileIDs() {
        #expect(TunnelConfig.profileID(name: "x") == "tunnel:x")
        #expect(TunnelConfig.name(fromProfileID: "tunnel:x") == "x")
        #expect(TunnelConfig.name(fromProfileID: "80F9E491") == nil)
        let p = VPNProfile(tunnel: TunnelConfig(name: "x", kind: .openfortivpn, host: "gw.example", port: 8443, saml: true), displayName: "X")
        #expect(p.id == "tunnel:x")
        #expect(p.providerKind == .openfortivpn)
        #expect(p.isOwnTunnel)
    }

    @Test func providerKindsForTunnels() {
        #expect(ProviderKind(bundleID: TunnelConfig.Kind.openfortivpn.providerBundleID) == .openfortivpn)
        #expect(ProviderKind(bundleID: TunnelConfig.Kind.openconnect.providerBundleID) == .openconnect)
        #expect(ProviderKind.openfortivpn.isOwnTunnel)
        #expect(!ProviderKind.forticlient.isOwnTunnel)
    }

    @Test func gatewayParsing() {
        #expect(TunnelConfig.parseGateway("fg.example.com") == .init(host: "fg.example.com", port: nil, realm: nil))
        #expect(TunnelConfig.parseGateway("https://fg.example.com/sso:8443") == nil || TunnelConfig.parseGateway("https://fg.example.com/sso:8443")?.host == "fg.example.com")
        #expect(TunnelConfig.parseGateway("https://fg.example.com:8443/sso") == .init(host: "fg.example.com", port: 8443, realm: "sso"))
        #expect(TunnelConfig.parseGateway("fg.example.com/sso") == .init(host: "fg.example.com", port: nil, realm: "sso"))
        #expect(TunnelConfig.parseGateway("FG.Example.com:10443/") == .init(host: "fg.example.com", port: 10443, realm: nil))
        #expect(TunnelConfig.parseGateway("https://fg.example.com/a/b") == .init(host: "fg.example.com", port: nil, realm: nil))
        #expect(TunnelConfig.parseGateway("  ") == nil)
        let t = TunnelConfig(name: "x", kind: .openfortivpn, host: "https://fg.example.com:8443/sso", port: 443, saml: true).normalized
        #expect(t.host == "fg.example.com")
        #expect(t.port == 8443)
        #expect(t.realm == "sso")
        let keep = TunnelConfig(name: "x", kind: .openfortivpn, host: "fg.example.com/sso", port: 8443, realm: "other").normalized
        #expect(keep.realm == "other")
        #expect(keep.port == 8443)
    }

    @Test func codingDefaults() throws {
        let json = #"{"name":"x","kind":"openconnect","host":"h"}"#.data(using: .utf8)!
        let t = try JSONDecoder().decode(TunnelConfig.self, from: json)
        #expect(t.port == 443)
        #expect(!t.saml)
        #expect(!t.hasSecret)
        #expect(t.extraArguments.isEmpty)
    }
}

@Suite struct TunnelFilesTests {
    @Test func plist() {
        let plist = TunnelFiles.launchdPlist(name: "corp", helper: "/usr/local/libexec/vpn-widget/vpn-tunnel")
        #expect(plist.contains("<string>com.ya-makariy.vpn-widget.corp</string>"))
        #expect(plist.contains("<string>run</string>\n\t\t<string>corp</string>"))
        #expect(plist.contains("<key>RunAtLoad</key>\n\t<false/>"))
        #expect(plist.contains("/var/log/vpn-widget/corp.log"))
    }

    @Test func sudoers() {
        let rule = TunnelFiles.sudoersRule(user: "alice")
        #expect(rule.contains("alice ALL=(root) NOPASSWD: /bin/launchctl kickstart -k system/com.ya-makariy.vpn-widget.*, /bin/launchctl kill TERM system/com.ya-makariy.vpn-widget.*, /bin/launchctl print system/com.ya-makariy.vpn-widget.*"))
        #expect(rule.hasSuffix("\n"))
    }

    @Test func commandsAndScripts() {
        #expect(TunnelFiles.kickstartCommand(name: "corp") == ["sudo", "-n", "/bin/launchctl", "kickstart", "-k", "system/com.ya-makariy.vpn-widget.corp"])
        #expect(TunnelFiles.killCommand(name: "corp") == ["sudo", "-n", "/bin/launchctl", "kill", "TERM", "system/com.ya-makariy.vpn-widget.corp"])
        let install = TunnelFiles.installScript(name: "corp", stagedConfig: "/tmp/s/corp.json", stagedSecret: "/tmp/s/corp.secret")
        #expect(install.contains("'/usr/local/libexec/vpn-widget/vpn-tunnel' install 'corp' '/tmp/s/corp.json' '/tmp/s/corp.secret'"))
        #expect(install.contains("/bin/rm -f '/tmp/s/corp.secret'"))
        let refreshed = TunnelFiles.installScript(name: "corp", stagedConfig: "/tmp/s/corp.json", stagedSecret: nil, refreshHelperFrom: "/A/vpn-tunnel")
        #expect(refreshed.hasPrefix("set -e\n/usr/bin/install -m 755 -o root -g wheel '/A/vpn-tunnel' '/usr/local/libexec/vpn-widget/vpn-tunnel'\n"))
        let setup = TunnelFiles.setupScript(bundledHelper: "/Applications/VPN Widget.app/Contents/MacOS/vpn-tunnel", user: "me", homebrewPrefix: "/opt/homebrew")
        #expect(setup.contains("/usr/bin/install -m 755 -o root -g wheel '/Applications/VPN Widget.app/Contents/MacOS/vpn-tunnel' '/usr/local/libexec/vpn-widget/vpn-tunnel'"))
        #expect(setup.contains("'/usr/local/libexec/vpn-widget/vpn-tunnel' setup 'me' '/opt/homebrew'"))
    }
}

@Suite struct TunnelStateTests {
    @Test func rawStatus() {
        let t0 = Date()
        #expect(TunnelState(phase: .connected, since: t0).rawStatus(daemonAlive: true) == .connected)
        #expect(TunnelState(phase: .connected, since: t0).rawStatus(daemonAlive: false) == .disconnected)
        #expect(TunnelState(phase: .waitingForSignIn, since: t0).rawStatus(daemonAlive: true) == .connecting)
        #expect(TunnelState(phase: .waitingForGateway, since: t0).rawStatus(daemonAlive: true) == .connecting)
        #expect(TunnelState(phase: .failed, since: t0).rawStatus(daemonAlive: false) == .failed)
        #expect(TunnelState(phase: .stopped, since: t0).rawStatus(daemonAlive: true) == .disconnected)
        #expect(deriveState(raw: .failed, inDirectory: true) == .failed)
        #expect(ConnectionState.failed.actions == Actions(connect: true))
    }

    @Test func roundTrip() throws {
        let s = TunnelState(phase: .waitingForSignIn, since: Date(timeIntervalSince1970: 1_700_000_000), signInURL: "https://gw.example:8443/remote/saml/start?redirect=1&realm=sso", signInAttempt: 2, pid: 42)
        let data = try TunnelState.encoder.encode(s)
        let back = try TunnelState.decoder.decode(TunnelState.self, from: data)
        #expect(back.phase == .waitingForSignIn)
        #expect(back.signInAttempt == 2)
        #expect(back.signInURL == s.signInURL)
        #expect(!String(decoding: data, as: UTF8.self).contains("password"))
    }
}

@Suite struct ToolOutputTests {
    @Test func openfortivpn() {
        #expect(OpenFortiVPNOutput.parse("INFO:   Authenticate at 'https://gw.example:8443/remote/saml/start?redirect=1&realm=sso'") == .signInURL("https://gw.example:8443/remote/saml/start?redirect=1&realm=sso"))
        #expect(OpenFortiVPNOutput.parse("ERROR:  Timeout listening for incoming HTTP connection reached") == .signInTimedOut)
        #expect(OpenFortiVPNOutput.parse("INFO:   Got addresses: [10.0.0.5], ns [10.0.0.53, 10.0.0.54]") == .addresses(ip: "10.0.0.5", dns: ["10.0.0.53", "10.0.0.54"]))
        #expect(OpenFortiVPNOutput.parse("INFO:   Got addresses: [10.0.0.5], ns [0.0.0.0, 0.0.0.0]") == .addresses(ip: "10.0.0.5", dns: ["0.0.0.0", "0.0.0.0"]))
        #expect(OpenFortiVPNOutput.parse("INFO:   Interface ppp0 is UP.") == .up(interface: "ppp0", address: nil))
        #expect(OpenFortiVPNOutput.parse("INFO:   Tunnel is up and running.") == .up(interface: nil, address: nil))
        #expect(OpenFortiVPNOutput.parse("INFO:   Logged out.") == .down("Logged out."))
        #expect(OpenFortiVPNOutput.parse("ERROR:  Could not authenticate to gateway. Please check the password, client certificate, etc.") == .authenticationFailed("ERROR:  Could not authenticate to gateway. Please check the password, client certificate, etc."))
        #expect(OpenFortiVPNOutput.parse("ERROR:  connect: Connection refused") == .error("connect: Connection refused"))
        #expect(OpenFortiVPNOutput.parse("DEBUG:  Resolving gateway host") == nil)
    }

    @Test func openconnect() {
        #expect(OpenConnectOutput.parse("Connected utun6 as 172.16.0.5, using SSL, with DTLS in progress") == .up(interface: "utun6", address: "172.16.0.5"))
        #expect(OpenConnectOutput.parse("Configured as 172.16.0.5, with SSL connected and DTLS connected") == .up(interface: nil, address: "172.16.0.5"))
        #expect(OpenConnectOutput.parse("Session authentication will expire at Mon, 16 Nov 2026 17:30:06 MSK") == nil)
        #expect(OpenConnectOutput.parse("Login failed.") == .authenticationFailed("Login failed."))
        #expect(OpenConnectOutput.parse("Failed to connect to host gw.example") == .error("Failed to connect to host gw.example"))
        #expect(OpenConnectOutput.parse("Logout successful.") == .down("Logout successful."))
        #expect(OpenConnectOutput.parse("Got CONNECT response: HTTP/1.1 200 OK") == nil)
        #expect(OpenConnectOutput.parse("    --servercert pin-sha256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=") == .untrustedCertificate("pin-sha256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="))
    }

    @Test func untrustedGatewayCertificates() {
        #expect(OpenFortiVPNOutput.parse("ERROR:  Gateway certificate validation failed, and the certificate digest is not in the local whitelist. If you trust it, rerun with:") == .error("Gateway certificate validation failed, and the certificate digest is not in the local whitelist. If you trust it, rerun with:"))
        #expect(OpenFortiVPNOutput.parse("ERROR:      --trusted-cert 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef") == .untrustedCertificate("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"))
    }

    @Test func backoff() {
        var b = Backoff()
        #expect(b.next(sessionLasted: 0) == 5)
        #expect(b.next(sessionLasted: 0) == 10)
        #expect(b.next(sessionLasted: 0) == 20)
        for _ in 0..<10 { _ = b.next(sessionLasted: 0) }
        #expect(b.next(sessionLasted: 0) == 300)
        #expect(b.next(sessionLasted: 120) == 5)
        b.reset()
        #expect(b.next(sessionLasted: 0) == 5)
    }
}

@Suite struct InterfaceLookupTests {
    @Test func loopbackByAddress() {
        #expect(InterfaceStatistics.interface(withAddress: "127.0.0.1") == "lo0")
        #expect(InterfaceStatistics.interface(withAddress: "203.0.113.77") == nil)
    }
}

@Suite struct TunnelEngineTests {
    @Test func signInURLAndFailureFlowIntoTheState() async throws {
        let tunnel = TunnelConfig(name: "corp", kind: .openfortivpn, host: "gw.example", port: 8443, saml: true)
        let p = VPNProfile(tunnel: tunnel, displayName: "Corp")
        let rig = Rig(profiles: [p], statuses: [p.id: .connecting])
        let url = URL(string: "https://gw.example:8443/remote/saml/start")!
        await rig.controller.setExtended(p.id, ExtendedStatus(lastChange: rig.now.now, signInURL: url, signInAttempt: 1, signInRun: 42, message: "Sign in in the browser"))
        var s = await rig.engine.poll()
        #expect(s.profiles[0].state == .connecting)
        #expect(s.profiles[0].signInURL == url)
        #expect(s.profiles[0].signInAttempt == 1)
        #expect(s.profiles[0].signInRun == 42)
        #expect(s.profiles[0].clientHint == "Sign in in the browser")

        await rig.controller.set(p.id, .failed)
        await rig.controller.setExtended(p.id, ExtendedStatus(message: "Could not authenticate to gateway", untrustedCertificate: "pin-sha256:abc="))
        s = await rig.engine.poll()
        #expect(s.profiles[0].state == .failed)
        #expect(s.profiles[0].failure == "Could not authenticate to gateway")
        #expect(s.profiles[0].untrustedCertificate == "pin-sha256:abc=")
        #expect(s.level == .problem)
        #expect(s.profiles[0].signInURL == nil)
    }
}

@Suite struct SignInPromptsTests {
    @Test func opensOncePerAttempt() {
        var prompts = SignInPrompts()
        #expect(prompts.shouldOpen(key: "a", run: 100, attempt: 1) == true)
        #expect(prompts.shouldOpen(key: "a", run: 100, attempt: 1) == false)
        #expect(prompts.shouldOpen(key: "a", run: 100, attempt: 1) == false)
    }

    @Test func opensAgainForANewAttempt() {
        var prompts = SignInPrompts()
        #expect(prompts.shouldOpen(key: "a", run: 100, attempt: 1) == true)
        #expect(prompts.shouldOpen(key: "a", run: 100, attempt: 2) == true)
        #expect(prompts.shouldOpen(key: "a", run: 100, attempt: 2) == false)
    }

    /// A daemon started again after a failure counts from one again, and the
    /// app may not have seen the failure between two polls.
    @Test func opensAgainAfterARestart() {
        var prompts = SignInPrompts()
        #expect(prompts.shouldOpen(key: "a", run: 100, attempt: 1) == true)
        #expect(prompts.shouldOpen(key: "a", run: 101, attempt: 1) == true)
        #expect(prompts.shouldOpen(key: "a", run: 101, attempt: 1) == false)
    }

    @Test func forgetsAndKeepsProfilesApart() {
        var prompts = SignInPrompts()
        #expect(prompts.shouldOpen(key: "a", run: 100, attempt: 1) == true)
        #expect(prompts.shouldOpen(key: "b", run: 100, attempt: 1) == true)
        prompts.forget(key: "a")
        #expect(prompts.shouldOpen(key: "a", run: 100, attempt: 1) == true)
        #expect(prompts.shouldOpen(key: "b", run: 100, attempt: 1) == false)
    }
}

@Suite struct TunnelLogTests {
    private func temporaryFile(_ text: String) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tunnel-log-\(UUID().uuidString).log")
        try Data(text.utf8).write(to: url)
        return url.path
    }

    @Test func missingFile() {
        #expect(TunnelLog.tail(path: "/nonexistent/vpn-widget/x.log") == nil)
        #expect(TunnelLog.read(path: "/nonexistent/vpn-widget/x.log", from: 0) == nil)
    }

    @Test func wholeFileWhenSmall() throws {
        let path = try temporaryFile("one\ntwo\n")
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(TunnelLog.tail(path: path) == TunnelLog.Tail(text: "one\ntwo\n", fileSize: 8, truncated: false))
    }

    @Test func tailStartsAtAWholeLine() throws {
        let path = try temporaryFile("first line\nsecond line\nthird\n")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let tail = try #require(TunnelLog.tail(path: path, maxBytes: 12))
        #expect(tail.text == "third\n")
        #expect(tail.truncated)
        #expect(tail.fileSize == 29)
        // One line longer than the window: nothing whole to show.
        #expect(TunnelLog.tail(path: path, maxBytes: 3)?.text == "")
    }

    @Test func readsWhatWasAppended() throws {
        let path = try temporaryFile("one\n")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let tail = try #require(TunnelLog.tail(path: path))
        #expect(TunnelLog.read(path: path, from: tail.fileSize)?.text == "")
        let handle = try #require(FileHandle(forWritingAtPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("two\n".utf8))
        try handle.close()
        let more = try #require(TunnelLog.read(path: path, from: tail.fileSize))
        #expect(more.text == "two\n")
        #expect(more.offset == 8)
        // A replaced, shorter file is read from its start.
        try Data("new\n".utf8).write(to: URL(fileURLWithPath: path))
        let again = try #require(TunnelLog.read(path: path, from: more.offset))
        #expect(again.text == "new\n")
        #expect(again.offset == 4)
    }

    @Test func lastLines() {
        #expect(TunnelLog.lastLines("a\nb\nc\n", 2) == "b\nc")
        #expect(TunnelLog.lastLines("a\nb\nc", 2) == "b\nc")
        #expect(TunnelLog.lastLines("a\n", 5) == "a")
        #expect(TunnelLog.lastLines("", 5) == "")
        #expect(TunnelLog.lastLines("a\nb\n", 0) == "")
    }
}

@Suite struct TunnelLogRotationTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tashkent")!
        return c
    }

    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    @Test func daysAreLocal() {
        // 20:30 UTC is already the next day at UTC+5.
        #expect(TunnelLogRotation.day(date("2026-11-15T20:30:00Z"), calendar: calendar) == "2026-11-16")
        #expect(TunnelLogRotation.day(date("2026-11-15T18:30:00Z"), calendar: calendar) == "2026-11-15")
    }

    @Test func dueAfterMidnight() {
        let now = date("2026-11-15T19:00:10Z") // 00:00:10 on the 16th
        #expect(TunnelLogRotation.isDue(modified: date("2026-11-15T18:59:50Z"), now: now, calendar: calendar))
        #expect(!TunnelLogRotation.isDue(modified: date("2026-11-15T19:00:05Z"), now: now, calendar: calendar))
        #expect(TunnelLogRotation.isDue(modified: date("2026-11-01T10:00:00Z"), now: now, calendar: calendar))
    }

    @Test func archiveNames() {
        #expect(TunnelLogRotation.archivePath(name: "corp", day: "2026-11-15") == "/var/log/vpn-widget/corp.2026-11-15.log")
        #expect(TunnelLogRotation.archivePath(name: "corp", day: "2026-11-15", sequence: 2) == "/var/log/vpn-widget/corp.2026-11-15-2.log")
        #expect(TunnelLogRotation.archiveDay(fileName: "corp.2026-11-15.log.gz", name: "corp") == "2026-11-15")
        #expect(TunnelLogRotation.archiveDay(fileName: "corp.2026-11-15.log", name: "corp") == "2026-11-15")
        #expect(TunnelLogRotation.archiveDay(fileName: "corp.2026-11-15-2.log.gz", name: "corp") == "2026-11-15")
        #expect(TunnelLogRotation.archiveDay(fileName: "corp.log", name: "corp") == nil)
        #expect(TunnelLogRotation.archiveDay(fileName: "corp-sso.2026-11-15.log.gz", name: "corp") == nil)
        #expect(TunnelLogRotation.archiveDay(fileName: "corp.2026-11-15x.log.gz", name: "corp") == nil)
        #expect(TunnelLogRotation.archiveDay(fileName: "corp.notes.log", name: "corp") == nil)
    }

    @Test func retention() {
        let files = ["corp.log", "corp.2026-11-15.log.gz", "corp.2026-11-09.log.gz", "corp.2026-11-08.log.gz", "corp.2026-10-01.log", "other.2026-01-01.log.gz"]
        let now = date("2026-11-16T07:00:00Z")
        #expect(TunnelLogRotation.expired(fileNames: files, name: "corp", now: now, keepDays: 7, calendar: calendar) == ["corp.2026-10-01.log", "corp.2026-11-08.log.gz"])
        #expect(TunnelLogRotation.expired(fileNames: files, name: "corp", now: now, keepDays: 1, calendar: calendar) == ["corp.2026-10-01.log", "corp.2026-11-08.log.gz", "corp.2026-11-09.log.gz"])
        #expect(TunnelLogRotation.expired(fileNames: files, name: "corp", now: now, keepDays: 365, calendar: calendar).isEmpty)
    }

    @Test func levels() {
        typealias Level = TunnelConfig.LogLevel
        #expect(Level.info.includes(.error) && Level.info.includes(.info))
        #expect(!Level.info.includes(.debug) && !Level.error.includes(.info))
        #expect(Level.trace.includes(.debug) && !Level.debug.includes(.trace))
        #expect(Level.ofToolLine("ERROR:  Could not authenticate") == .error)
        #expect(Level.ofToolLine("WARN:   Bad port") == .info)
        #expect(Level.ofToolLine("INFO:   Tunnel is up and running.") == .info)
        #expect(Level.ofToolLine("DEBUG:  Got Address: 10.0.0.2") == .debug)
        #expect(Level.ofToolLine("DEBUG:  pppd ---> gateway (20 bytes)") == .trace)
        #expect(Level.ofToolLine("Connected as 10.0.0.2, using SSL") == .info)
        #expect(Level.ofToolLine("Failed to connect to host gw.example") == .error)
        #expect(Level.info.toolArguments(.openfortivpn) == ["-v"])
        #expect(Level.trace.toolArguments(.openfortivpn) == ["-v", "-v"])
        #expect(Level.info.toolArguments(.openconnect).isEmpty)
        #expect(Level.debug.toolArguments(.openconnect) == ["-v"])
    }

    @Test func configDefaultsAndCoding() throws {
        let old = #"{"name":"corp","kind":"openconnect","host":"gw.example"}"#
        let decoded = try JSONDecoder().decode(TunnelConfig.self, from: Data(old.utf8))
        #expect(decoded.logLevel == .info)
        #expect(decoded.logRetentionDays == 7)
        var config = decoded
        config.logLevel = .trace
        config.logRetentionDays = 30
        #expect(try JSONDecoder().decode(TunnelConfig.self, from: JSONEncoder().encode(config)) == config)
        let odd = #"{"name":"corp","kind":"openconnect","host":"gw.example","logLevel":"loud","logRetentionDays":0}"#
        let lenient = try JSONDecoder().decode(TunnelConfig.self, from: Data(odd.utf8))
        #expect(lenient.logLevel == .info)
        #expect(lenient.logRetentionDays == 1)
    }
}
