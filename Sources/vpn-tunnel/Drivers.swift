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
        /// amneziawg: the config the runner applies once the tool has its interface.
        var wireGuard: WireGuardConf?
    }

    static func launch(for profile: VPNProfile) throws -> Launch {
        guard let tunnel = profile.tunnel else { throw ActionError("not a tunnel profile") }
        switch tunnel.kind {
        case .openfortivpn: return try openfortivpn(profile, tunnel)
        case .openconnect: return try openconnect(profile, tunnel)
        case .amneziawg: return try amneziawg(profile, tunnel)
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
        var arguments = ["-c", config] + tunnel.logLevel.toolArguments(.openfortivpn) + ["--set-dns=0", "--pppd-use-peerdns=\(splitDNS ? 0 : 1)", "--pppd-accept-remote=1"]
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
        // The wrapper is setup's, but a newer daemon may want more of it: kept current here.
        let wrapper = "\(TunnelFiles.libexecDirectory)/vpnc-wrapper"
        if (try? String(contentsOfFile: wrapper, encoding: .utf8)) != vpncWrapperScript {
            try Admin.writeRoot(vpncWrapperScript, to: wrapper, mode: 0o755)
        }
        try? FileManager.default.removeItem(atPath: TunnelFiles.recordedRoutesPath(tunnel.name))
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
        arguments += tunnel.logLevel.toolArguments(.openconnect)
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

    /// amneziawg-go runs in the foreground on a utun the system numbers, and
    /// writes its name where `WG_TUN_NAME_FILE` says; the rest of what
    /// wg-quick would do is WireGuardLink's. The `.conf`, with its keys, is the
    /// tunnel's secret, read here and never passed on a command line. Plain
    /// WireGuard configs take the same path: without obfuscation parameters
    /// amneziawg-go is expected to speak the plain protocol.
    static func amneziawg(_ profile: VPNProfile, _ tunnel: TunnelConfig) throws -> Launch {
        for tool in TunnelFiles.wireGuardTools where !FileManager.default.isExecutableFile(atPath: "\(TunnelFiles.libexecDirectory)/\(tool)") {
            throw ActionError("\(tool) is not in \(TunnelFiles.libexecDirectory): install it, then Set Up Again in Settings → Tunnels")
        }
        let conf = try Admin.wireGuardConf(name: tunnel.name, stagedSecret: nil)
        let nameFile = TunnelFiles.interfaceNamePath(tunnel.name)
        try? FileManager.default.removeItem(atPath: nameFile)
        var environment = ["WG_TUN_NAME_FILE": nameFile]
        // It logs errors only unless told otherwise.
        if tunnel.logLevel >= .debug { environment["LOG_LEVEL"] = "verbose" }
        return Launch(
            executable: "\(TunnelFiles.libexecDirectory)/amneziawg-go",
            arguments: ["-f", "utun"],
            environment: environment,
            parse: AmneziaWGOutput.parse,
            wireGuard: conf
        )
    }

    /// Installed next to the tools. Records the DNS the gateway pushed and
    /// the networks it asked to route, the address pool's among them
    /// (vpnc-script may fail to add a route
    /// another tunnel has; the daemon still has to know the network is ours),
    /// then runs vpnc-script, without DNS when the domains are ours. The
    /// values are only printed, never run: the daemon parses them strictly.
    static let vpncWrapperScript = """
    #!/bin/sh
    # VPN Widget: around vpnc-script. See vpn-tunnel.
    if [ "$reason" = "connect" ] && [ -n "$VPN_WIDGET_NAME" ]; then
        dir="${VPN_WIDGET_STATE_DIR:-/var/run/vpn-widget}"
        printf '%s\\n%s\\n' "$INTERNAL_IP4_DNS" "$CISCO_DEF_DOMAIN" > "$dir/$VPN_WIDGET_NAME.dns"
        : > "$dir/$VPN_WIDGET_NAME.routes"
        # The network of the address pool, which vpnc-script routes too.
        if [ -n "$INTERNAL_IP4_NETADDR" ] && [ -n "$INTERNAL_IP4_NETMASKLEN" ]; then
            printf '%s/%s\\n' "$INTERNAL_IP4_NETADDR" "$INTERNAL_IP4_NETMASKLEN" >> "$dir/$VPN_WIDGET_NAME.routes"
        fi
        i=0
        while [ "$i" -lt "${CISCO_SPLIT_INC:-0}" ] 2>/dev/null; do
            eval "addr=\\${CISCO_SPLIT_INC_${i}_ADDR} len=\\${CISCO_SPLIT_INC_${i}_MASKLEN}"
            printf '%s/%s\\n' "$addr" "$len" >> "$dir/$VPN_WIDGET_NAME.routes"
            i=$((i + 1))
        done
    fi
    if [ "$VPN_WIDGET_SPLIT_DNS" = "1" ]; then
        INTERNAL_IP4_DNS= INTERNAL_IP6_DNS= CISCO_DEF_DOMAIN= CISCO_SPLIT_DNS=
        export INTERNAL_IP4_DNS INTERNAL_IP6_DNS CISCO_DEF_DOMAIN CISCO_SPLIT_DNS
    fi
    exec "$(dirname "$0")/vpnc-script" "$@"

    """
}
