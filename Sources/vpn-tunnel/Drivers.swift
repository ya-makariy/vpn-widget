import Foundation
import VPNWidgetCore

/// How each tool is started, and how its output is read.
enum Drivers {
    struct Launch {
        var executable: String
        var arguments: [String]
        var environment: [String: String] = [:]
        var stdin: Data?
        var parse: (String) -> ToolEvent?
    }

    static func launch(for profile: VPNProfile) throws -> Launch {
        guard let tunnel = profile.tunnel else { throw ActionError("not a tunnel profile") }
        switch tunnel.kind {
        case .openfortivpn: return try openfortivpn(profile, tunnel)
        case .openconnect: return try openconnect(profile, tunnel)
        }
    }

    static func secret(_ tunnel: TunnelConfig) -> String? {
        guard tunnel.hasSecret, let data = FileManager.default.contents(atPath: TunnelFiles.secretPath(tunnel.name)) else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    /// openfortivpn reads host, credentials and options from a root-only
    /// config file, so that nothing shows in the process list. DNS is left to
    /// us when the profile names domains; otherwise pppd takes the gateway's
    /// servers for everything, as FortiClient would.
    static func openfortivpn(_ profile: VPNProfile, _ tunnel: TunnelConfig) throws -> Launch {
        var lines = ["host = \(tunnel.host)", "port = \(tunnel.port)"]
        if let realm = tunnel.realm, !realm.isEmpty { lines.append("realm = \(realm)") }
        if let user = tunnel.username, !user.isEmpty { lines.append("username = \(user)") }
        if let password = secret(tunnel) { lines.append("password = \(password)") }
        if let cert = tunnel.trustedCert, !cert.isEmpty { lines.append("trusted-cert = \(cert)") }
        let splitDNS = !profile.dnsDomains.isEmpty
        let config = "\(TunnelFiles.generatedDirectory)/\(tunnel.name).conf"
        try Admin.writeRoot(lines.joined(separator: "\n") + "\n", to: config, mode: 0o600)
        // Options go on the command line, where their spelling is documented.
        var arguments = ["-c", config, "-v", "--set-dns=0", "--pppd-use-peerdns=\(splitDNS ? 0 : 1)", "--pppd-accept-remote=1"]
        if tunnel.saml { arguments.append("--saml-login") }
        return Launch(
            executable: "\(TunnelFiles.libexecDirectory)/openfortivpn",
            arguments: arguments + tunnel.extraArguments,
            parse: OpenFortiVPNOutput.parse
        )
    }

    /// openconnect gets the password on stdin and our vpnc-script wrapper,
    /// which records the DNS the gateway pushed and, when the profile names
    /// domains, keeps vpnc-script from making that DNS the system's.
    static func openconnect(_ profile: VPNProfile, _ tunnel: TunnelConfig) throws -> Launch {
        var arguments = [
            "--non-inter", "--script", "\(TunnelFiles.libexecDirectory)/vpnc-wrapper",
            "--protocol", tunnel.protocolName ?? "anyconnect",
        ]
        if let user = tunnel.username, !user.isEmpty { arguments += ["--user", user] }
        if let group = tunnel.realm, !group.isEmpty { arguments += ["--authgroup", group] }
        if let pin = tunnel.trustedCert, !pin.isEmpty { arguments += ["--servercert", pin] }
        var stdin: Data?
        if let password = secret(tunnel) {
            arguments.append("--passwd-on-stdin")
            stdin = Data((password + "\n").utf8)
        }
        arguments += tunnel.extraArguments
        arguments.append(tunnel.port == 443 ? tunnel.host : "\(tunnel.host):\(tunnel.port)")
        return Launch(
            executable: "\(TunnelFiles.libexecDirectory)/openconnect",
            arguments: arguments,
            environment: [
                "VPN_WIDGET_NAME": tunnel.name,
                "VPN_WIDGET_SPLIT_DNS": profile.dnsDomains.isEmpty ? "0" : "1",
                "VPN_WIDGET_STATE_DIR": TunnelFiles.stateDirectory,
            ],
            stdin: stdin,
            parse: OpenConnectOutput.parse
        )
    }

    /// Installed next to the tools. Records the DNS the gateway pushed for the
    /// daemon, then runs vpnc-script, without DNS when the domains are ours.
    static let vpncWrapperScript = """
    #!/bin/sh
    # VPN Widget: around vpnc-script. See vpn-tunnel.
    if [ "$reason" = "connect" ] && [ -n "$VPN_WIDGET_NAME" ]; then
        printf '%s\\n%s\\n' "$INTERNAL_IP4_DNS" "$CISCO_DEF_DOMAIN" > "${VPN_WIDGET_STATE_DIR:-/var/run/vpn-widget}/$VPN_WIDGET_NAME.dns"
    fi
    if [ "$VPN_WIDGET_SPLIT_DNS" = "1" ]; then
        INTERNAL_IP4_DNS= INTERNAL_IP6_DNS= CISCO_DEF_DOMAIN= CISCO_SPLIT_DNS=
        export INTERNAL_IP4_DNS INTERNAL_IP6_DNS CISCO_DEF_DOMAIN CISCO_SPLIT_DNS
    fi
    exec "$(dirname "$0")/vpnc-script" "$@"

    """
}
