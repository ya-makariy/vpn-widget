import Foundation

/// Where own tunnels live on disk, and the files that make one: the launchd
/// plist, the sudoers rule and the scripts the admin prompt runs.
public enum TunnelFiles {
    public static let labelPrefix = "com.ya-makariy.vpn-widget."
    public static let libexecDirectory = "/usr/local/libexec/vpn-widget"
    public static let helperPath = libexecDirectory + "/vpn-tunnel"
    public static let configDirectory = "/usr/local/etc/vpn-widget/tunnels"
    public static let secretsDirectory = "/usr/local/etc/vpn-widget/secrets"
    public static let generatedDirectory = "/usr/local/etc/vpn-widget/generated"
    public static let stateDirectory = "/var/run/vpn-widget"
    public static let logDirectory = "/var/log/vpn-widget"
    public static let launchDaemonsDirectory = "/Library/LaunchDaemons"
    public static let sudoersPath = "/etc/sudoers.d/vpn-widget"
    public static let launchctl = "/bin/launchctl"

    /// Tools copied root-owned next to the helper, so that the passwordless
    /// start never runs a file the user can edit.
    public static let tools = ["openfortivpn", "openconnect", "vpnc-script"]

    /// AmneziaWG's tools, copied the same way. Homebrew has no formulae for
    /// them, so they are also looked for where their `make install` puts them.
    public static let wireGuardTools = ["amneziawg-go", "awg"]

    public static func wireGuardToolSources(_ tool: String, homebrewPrefix: String) -> [String] {
        var seen: [String] = []
        for directory in ["\(homebrewPrefix)/bin", "/usr/local/bin"] where !seen.contains(directory) { seen.append(directory) }
        return seen.map { "\($0)/\(tool)" }
    }

    public enum WireGuardToolStatus: Equatable, Sendable {
        /// Root-owned copies are in place.
        case ready
        /// Found on this Mac but not copied yet: setup has to run again.
        case needsSetup([String])
        /// Not found anywhere they are looked for.
        case missing([String])
    }

    public static func wireGuardToolStatus(homebrewPrefix: String, isExecutable: (String) -> Bool) -> WireGuardToolStatus {
        let absent = wireGuardTools.filter { !isExecutable("\(libexecDirectory)/\($0)") }
        guard !absent.isEmpty else { return .ready }
        let missing = absent.filter { tool in !wireGuardToolSources(tool, homebrewPrefix: homebrewPrefix).contains(where: isExecutable) }
        return missing.isEmpty ? .needsSetup(absent) : .missing(missing)
    }

    /// The stand-in ranges of all tunnels and the user's choices (FakeIP.Table).
    public static let fakeIPTablePath = "/usr/local/etc/vpn-widget/fakeip.json"
    /// A world-readable copy for the widget, next to the state files; the
    /// underscore keeps it apart from any tunnel's name.
    public static let publicFakeIPTablePath = "\(stateDirectory)/_fakeip.json"

    /// Which build of the helper a file is: its size and modification time,
    /// readable by anyone, changed by every install.
    public static func helperBuild(at path: String = helperPath) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int, let modified = attributes[.modificationDate] as? Date
        else { return nil }
        return "\(size)-\(Int(modified.timeIntervalSince1970))"
    }

    public static func label(_ name: String) -> String { labelPrefix + name }
    public static func plistPath(_ name: String) -> String { "\(launchDaemonsDirectory)/\(label(name)).plist" }
    public static func configPath(_ name: String) -> String { "\(configDirectory)/\(name).json" }
    public static func secretPath(_ name: String) -> String { "\(secretsDirectory)/\(name)" }
    public static func statePath(_ name: String) -> String { "\(stateDirectory)/\(name).json" }
    public static func logPath(_ name: String) -> String { "\(logDirectory)/\(name).log" }
    /// Where amneziawg-go writes the name of the utun it was given.
    public static func interfaceNamePath(_ name: String) -> String { "\(stateDirectory)/\(name).utun" }
    /// openconnect: the networks the gateway asked to route, `addr/len` a
    /// line, as the vpnc-script wrapper records them.
    public static func recordedRoutesPath(_ name: String) -> String { "\(stateDirectory)/\(name).routes" }
    /// A world-readable copy of the profile without secrets, for the widget's
    /// discovery; the config itself is root-only.
    public static func publicProfilePath(_ name: String) -> String { "\(stateDirectory)/\(name).profile.json" }

    /// The launchd job: started and stopped by the widget, never by itself.
    public static func launchdPlist(name: String, helper: String = helperPath) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>Label</key>
        \t<string>\(xml(label(name)))</string>
        \t<key>ProgramArguments</key>
        \t<array>
        \t\t<string>\(xml(helper))</string>
        \t\t<string>run</string>
        \t\t<string>\(xml(name))</string>
        \t</array>
        \t<key>RunAtLoad</key>
        \t<false/>
        \t<key>KeepAlive</key>
        \t<false/>
        \t<key>StandardOutPath</key>
        \t<string>\(xml(logPath(name)))</string>
        \t<key>StandardErrorPath</key>
        \t<string>\(xml(logPath(name)))</string>
        \t<key>EnvironmentVariables</key>
        \t<dict>
        \t\t<key>PATH</key>
        \t\t<string>/usr/bin:/bin:/usr/sbin:/sbin</string>
        \t</dict>
        </dict>
        </plist>

        """
    }

    /// Lets one user start, stop and look at the widget's jobs, and choose
    /// which tunnel holds a shared network (the helper checks the arguments),
    /// and nothing else.
    public static func sudoersRule(user: String) -> String {
        let jobs = "system/\(labelPrefix)*"
        return """
        # Written by VPN Widget: lets \(user) control the widget's own tunnels without a password.
        \(user) ALL=(root) NOPASSWD: \(launchctl) kickstart -k \(jobs), \(launchctl) kill TERM \(jobs), \(launchctl) print \(jobs), \(helperPath) set-owner *

        """
    }

    /// Chooses the tunnel that holds a shared network's real addresses; `-`
    /// forgets the choice.
    public static func setOwnerCommand(network: String, tunnel: String?) -> [String] {
        ["sudo", "-n", helperPath, "set-owner", network, tunnel ?? "-"]
    }

    /// The same through the admin prompt, for a setup from before the sudoers
    /// rule allowed it; the helper is replaced first when it is older too.
    public static func setOwnerScript(network: String, tunnel: String?, refreshHelperFrom bundledHelper: String? = nil) -> String {
        let q = ResolverFiles.shellQuote
        var lines = ["set -e"]
        if let bundledHelper {
            lines.append("/usr/bin/install -m 755 -o root -g wheel \(q(bundledHelper)) \(q(helperPath))")
        }
        lines.append("\(q(helperPath)) set-owner \(q(network)) \(q(tunnel ?? "-"))")
        return lines.joined(separator: "\n") + "\n"
    }

    public static func kickstartCommand(name: String) -> [String] { ["sudo", "-n", launchctl, "kickstart", "-k", "system/\(label(name))"] }
    public static func killCommand(name: String) -> [String] { ["sudo", "-n", launchctl, "kill", "TERM", "system/\(label(name))"] }
    public static func printCommand(name: String) -> [String] { ["sudo", "-n", launchctl, "print", "system/\(label(name))"] }

    /// The script the admin prompt runs once: installs the helper from the app
    /// bundle, then lets the helper finish (tools, directories, sudoers).
    public static func setupScript(bundledHelper: String, user: String, homebrewPrefix: String) -> String {
        let q = ResolverFiles.shellQuote
        return """
        set -e
        umask 022
        /usr/bin/install -d -m 755 -o root -g wheel \(q(libexecDirectory))
        /usr/bin/install -m 755 -o root -g wheel \(q(bundledHelper)) \(q(helperPath))
        \(q(helperPath)) setup \(q(user)) \(q(homebrewPrefix))

        """
    }

    /// With `refreshHelperFrom`, the helper is replaced first, so that an app
    /// update reaches the daemons at the next Apply without a separate setup.
    public static func installScript(name: String, stagedConfig: String, stagedSecret: String?, refreshHelperFrom bundledHelper: String? = nil) -> String {
        let q = ResolverFiles.shellQuote
        var lines = ["set -e"]
        if let bundledHelper {
            lines.append("/usr/bin/install -m 755 -o root -g wheel \(q(bundledHelper)) \(q(helperPath))")
        }
        lines.append("\(q(helperPath)) install \(q(name)) \(q(stagedConfig))\(stagedSecret.map { " " + q($0) } ?? "")")
        if let stagedSecret { lines.append("/bin/rm -f \(q(stagedSecret))") }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func removeScript(name: String) -> String {
        "set -e\n\(ResolverFiles.shellQuote(helperPath)) remove \(ResolverFiles.shellQuote(name))\n"
    }

    static func xml(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
