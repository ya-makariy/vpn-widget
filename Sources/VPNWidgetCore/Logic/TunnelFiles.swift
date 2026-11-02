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

    public static func label(_ name: String) -> String { labelPrefix + name }
    public static func plistPath(_ name: String) -> String { "\(launchDaemonsDirectory)/\(label(name)).plist" }
    public static func configPath(_ name: String) -> String { "\(configDirectory)/\(name).json" }
    public static func secretPath(_ name: String) -> String { "\(secretsDirectory)/\(name)" }
    public static func statePath(_ name: String) -> String { "\(stateDirectory)/\(name).json" }
    public static func logPath(_ name: String) -> String { "\(logDirectory)/\(name).log" }
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

    /// Lets one user start, stop and look at the widget's jobs, and nothing else.
    public static func sudoersRule(user: String) -> String {
        let jobs = "system/\(labelPrefix)*"
        return """
        # Written by VPN Widget: lets \(user) control the widget's own tunnels without a password.
        \(user) ALL=(root) NOPASSWD: \(launchctl) kickstart -k \(jobs), \(launchctl) kill TERM \(jobs), \(launchctl) print \(jobs)

        """
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
