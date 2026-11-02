import Foundation
import VPNWidgetCore

// vpnw: the widget's engine from the command line, for checking the system
// integration without the app. It reads the same profiles.json.

let usage = """
usage: vpnw <command>
  list                     VPN profiles the system knows, with status
  once [--all]             one poll of the configured profiles (--all: every profile)
  watch [seconds]          print status changes as the system reports them
  start <id|name>          start a profile (what the Connect button does)
  stop <id|name>           stop a profile
  dns <id|name>            the profile's DNS and routing facts
  check <url> [--insecure] run the reachability check against a URL
"""

@main
struct Main {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            print(usage)
            exit(2)
        }
        args.removeFirst()
        do {
            switch command {
            case "list": try await list()
            case "once": try await once(all: args.contains("--all"))
            case "watch": await watch(seconds: args.first.flatMap(Int.init) ?? 60)
            case "start", "stop": try await act(command, target: args.joined(separator: " "))
            case "dns": try await dns(target: args.joined(separator: " "))
            case "check": try await check(args)
            default:
                print(usage)
                exit(2)
            }
        } catch {
            fputs("vpnw: \(error)\n", stderr)
            exit(1)
        }
    }

    static let directory = ServiceDirectorySC()
    static let controller = ConnectionControllerSC()
    static let interfaces = InterfaceMapSC()

    static func resolve(_ target: String) async throws -> DiscoveredService {
        let services = try await directory.listVPNServices()
        if let s = services.first(where: { $0.id == target }) ?? services.first(where: { $0.name == target }) { return s }
        throw ActionError("no VPN profile named or identified \(target)")
    }

    static func list() async throws {
        for s in try await directory.listVPNServices() {
            let status = await controller.status(of: s.id)
            let state = deriveState(raw: status, inDirectory: true)
            print("\(s.id)  \(s.kind.displayName.padding(toLength: 11, withPad: " ", startingAt: 0))  \(state.text.padding(toLength: 13, withPad: " ", startingAt: 0))  \(s.name)\(s.enabled ? "" : "  (disabled)")")
        }
    }

    static func makeEngine(profiles: [VPNProfile]) -> PollEngine {
        PollEngine(profiles: profiles, ports: PollEngine.Ports(
            directory: directory,
            controller: controller,
            interfaces: interfaces,
            checker: ReachabilityCheckerURLSession(),
            notifier: PrintNotifier(),
            hooks: SystemProviderHooks()
        ))
    }

    static func once(all: Bool) async throws {
        let profiles: [VPNProfile]
        if all {
            profiles = try await directory.listVPNServices().map(VPNProfile.init(adopting:))
        } else {
            profiles = try ProfileStoreJSON().load().profiles
            if profiles.isEmpty { print("no profiles configured; use --all or the app's settings") }
        }
        let snapshot = await makeEngine(profiles: profiles).poll()
        print(format(snapshot))
    }

    static func format(_ s: Snapshot) -> String {
        var lines: [String] = []
        for p in s.profiles {
            var line = "\(p.profile.displayName) [\(p.profile.providerKind.displayName)]: \(p.statusText)"
            if let i = p.interfaceName { line += " on \(i)" }
            lines.append(line)
            let link = p.linkLine(now: s.at)
            if !link.isEmpty { lines.append("    " + link) }
            if p.checked { lines.append("    " + p.result.description) }
            if p.isPrimaryInterface { lines.append("    carries the default route") }
            if p.takesOverDNS { lines.append("    answers all DNS queries") }
            if let e = p.lastActionError { lines.append("    " + e) }
        }
        lines.append("level: \(s.level)\(s.doubtful ? ", rechecking" : "")")
        return lines.joined(separator: "\n")
    }

    static func watch(seconds: Int) async {
        let services = (try? await directory.listVPNServices()) ?? []
        let names = Dictionary(services.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let started = Date()
        @Sendable func stamp() -> String { String(format: "%6.1fs", Date().timeIntervalSince(started)) }
        await controller.setChangeHandler { id in
            Task {
                let status = await controller.status(of: id)
                print("\(stamp())  connection \(names[id] ?? id): \(status.map { "\($0)" } ?? "nil")")
            }
        }
        await interfaces.setChangeHandler { print("\(stamp())  dynamic store changed") }
        // Create the connections so that their callbacks are armed.
        for s in services { _ = await controller.status(of: s.id) }
        print("watching \(services.count) profiles for \(seconds)s; change a VPN in its client or with vpnw start/stop")
        try? await Task.sleep(for: .seconds(seconds))
    }

    static func act(_ verb: String, target: String) async throws {
        let s = try await resolve(target)
        let profile = VPNProfile(adopting: s)
        let hooks = SystemProviderHooks()
        print("\(verb) \(s.name) (\(s.kind.displayName)) …")
        if verb == "start" {
            try await hooks.start(profile, name: s.name, controller: controller)
        } else {
            try await hooks.stop(profile, name: s.name, controller: controller)
        }
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(500))
            let status = await controller.status(of: s.id)
            print("  \(status.map { "\($0)" } ?? "nil")")
            if verb == "start", status == .connected { break }
            if verb == "stop", status == .disconnected { break }
        }
    }

    static func dns(target: String) async throws {
        let s = try await resolve(target)
        print("status:", await controller.status(of: s.id).map { "\($0)" } ?? "nil")
        if let e = await controller.extendedStatus(of: s.id) {
            print("lastChange:", e.lastChange.map { "\($0)" } ?? "nil")
            print("dnsServers:", e.dnsServers)
            print("dnsSearchDomains:", e.dnsSearchDomains)
            print("isPrimaryInterface:", e.isPrimaryInterface)
            print("interfaceName (extended):", e.interfaceName ?? "nil")
        }
        print("link:", await interfaces.link(for: s.id).map { "\($0)" } ?? "nil")
        print("takesOverDNS:", await interfaces.takesOverDNS(s.id))
        print("installsDefaultRoute:", await interfaces.installsDefaultRoute(s.id))
        print("statistics:", await controller.statistics(of: s.id).map { $0.description } ?? "nil")
    }

    static func check(_ args: [String]) async throws {
        guard let raw = args.first(where: { !$0.hasPrefix("--") }), let url = URL(string: raw) else {
            throw ActionError("usage: vpnw check <url> [--insecure]")
        }
        let result = await ReachabilityCheckerURLSession().check(url, insecureTLS: args.contains("--insecure"))
        print(result.ok ? "ok" : "failed", "·", result.description)
    }
}

struct PrintNotifier: Notifier {
    func send(_ notice: Notice) async {
        print("notice: \(notice.summary)\(notice.body.isEmpty ? "" : " — " + notice.body)")
    }
}
