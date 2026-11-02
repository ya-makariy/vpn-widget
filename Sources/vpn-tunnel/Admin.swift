import Foundation
import VPNWidgetCore

/// The one-off root jobs: setting up, installing and removing tunnels.
enum Admin {
    static func requireRoot() throws {
        guard getuid() == 0 else { throw ActionError("must run as root") }
    }

    static func log(_ text: String) {
        print(text)
        fflush(stdout)
    }

    /// Directories, root-owned copies of the tools, the vpnc-script wrapper
    /// and the sudoers rule for the user.
    static func setup(user: String, homebrewPrefix: String) throws {
        guard user.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else { throw ActionError("bad user name") }
        let fm = FileManager.default
        for (path, mode) in [
            (TunnelFiles.libexecDirectory, 0o755), (TunnelFiles.configDirectory, 0o700), (TunnelFiles.secretsDirectory, 0o700),
            (TunnelFiles.generatedDirectory, 0o700), (TunnelFiles.stateDirectory, 0o755), (TunnelFiles.logDirectory, 0o755),
        ] {
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: mode])
            try fm.setAttributes([.posixPermissions: mode, .ownerAccountID: 0, .groupOwnerAccountID: 0], ofItemAtPath: path)
        }
        // Tools: copied so that the passwordless start never runs a file the user can edit.
        let sources = [
            "openfortivpn": "\(homebrewPrefix)/bin/openfortivpn",
            "openconnect": "\(homebrewPrefix)/bin/openconnect",
            "vpnc-script": "\(homebrewPrefix)/etc/vpnc/vpnc-script",
        ]
        for (tool, source) in sources {
            let resolved = (try? fm.destinationOfSymbolicLink(atPath: source)).map { URL(fileURLWithPath: $0, relativeTo: URL(fileURLWithPath: source).deletingLastPathComponent()).standardizedFileURL.path } ?? source
            guard fm.fileExists(atPath: resolved) else {
                log("skipping \(tool): \(source) is not installed (brew install \(tool == "vpnc-script" ? "openconnect" : tool))")
                continue
            }
            let target = "\(TunnelFiles.libexecDirectory)/\(tool)"
            try? fm.removeItem(atPath: target)
            try fm.copyItem(atPath: resolved, toPath: target)
            try fm.setAttributes([.posixPermissions: 0o755, .ownerAccountID: 0, .groupOwnerAccountID: 0], ofItemAtPath: target)
            log("installed \(target)")
        }
        try writeRoot(Drivers.vpncWrapperScript, to: "\(TunnelFiles.libexecDirectory)/vpnc-wrapper", mode: 0o755)
        // The sudoers rule, checked by visudo before it is put in place.
        let rule = TunnelFiles.sudoersRule(user: user)
        let temp = "\(TunnelFiles.generatedDirectory)/sudoers.tmp"
        try writeRoot(rule, to: temp, mode: 0o440)
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/sbin/visudo")
        check.arguments = ["-c", "-q", "-f", temp]
        try check.run()
        check.waitUntilExit()
        guard check.terminationStatus == 0 else { throw ActionError("visudo rejected the sudoers rule") }
        try? fm.removeItem(atPath: TunnelFiles.sudoersPath)
        try fm.moveItem(atPath: temp, toPath: TunnelFiles.sudoersPath)
        log("installed \(TunnelFiles.sudoersPath) for \(user)")
    }

    static func install(name: String, stagedConfig: String, stagedSecret: String?) throws {
        guard TunnelConfig.isValidName(name) else { throw ActionError("invalid tunnel name") }
        let data = try Data(contentsOf: URL(fileURLWithPath: stagedConfig))
        var profile = try TunnelState.decoder.decode(VPNProfile.self, from: data)
        guard var tunnel = profile.tunnel?.normalized, tunnel.name == name else { throw ActionError("the profile is not for tunnel \(name)") }
        let fm = FileManager.default
        if let stagedSecret {
            let secret = try Data(contentsOf: URL(fileURLWithPath: stagedSecret))
            try writeRoot(secret, to: TunnelFiles.secretPath(name), mode: 0o600)
            tunnel.hasSecret = true
        } else {
            tunnel.hasSecret = fm.fileExists(atPath: TunnelFiles.secretPath(name))
        }
        profile.tunnel = tunnel
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(profile)
        try writeRoot(encoded, to: TunnelFiles.configPath(name), mode: 0o600)
        try fm.createDirectory(atPath: TunnelFiles.stateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try writeRoot(encoded, to: TunnelFiles.publicProfilePath(name), mode: 0o644)
        // The job itself only changes when its plist does: a running tunnel
        // keeps running through a config change, and picks it up next start.
        let plistPath = TunnelFiles.plistPath(name)
        let label = "system/\(TunnelFiles.label(name))"
        let plist = TunnelFiles.launchdPlist(name: name)
        let unchanged = (try? String(contentsOfFile: plistPath, encoding: .utf8)) == plist
        if unchanged, launchctl(["print", label]) == 0 {
            log("updated tunnel \(name); the job is loaded already")
            return
        }
        if fm.fileExists(atPath: plistPath) {
            _ = launchctl(["kill", "TERM", label])
            _ = launchctl(["bootout", label])
            // bootout returns before the job is gone; bootstrap needs it gone.
            for _ in 0..<40 where launchctl(["print", label]) == 0 {
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        try writeRoot(plist, to: plistPath, mode: 0o644)
        var status: Int32 = -1
        for attempt in 0..<10 {
            status = launchctl(["bootstrap", "system", plistPath])
            if status == 0 { break }
            log("bootstrap attempt \(attempt + 1) failed (\(status)); retrying")
            Thread.sleep(forTimeInterval: 0.5)
        }
        guard status == 0 else { throw ActionError("launchctl bootstrap failed (\(status))") }
        log("installed tunnel \(name)")
    }

    static func remove(name: String) throws {
        guard TunnelConfig.isValidName(name) else { throw ActionError("invalid tunnel name") }
        let fm = FileManager.default
        _ = launchctl(["kill", "TERM", "system/\(TunnelFiles.label(name))"])
        _ = launchctl(["bootout", "system/\(TunnelFiles.label(name))"])
        for path in [TunnelFiles.plistPath(name), TunnelFiles.configPath(name), TunnelFiles.secretPath(name), TunnelFiles.statePath(name), TunnelFiles.publicProfilePath(name), "\(TunnelFiles.generatedDirectory)/\(name).conf"] {
            try? fm.removeItem(atPath: path)
        }
        log("removed tunnel \(name)")
    }

    static func launchctl(_ arguments: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: TunnelFiles.launchctl)
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return -1
        }
        p.waitUntilExit()
        return p.terminationStatus
    }

    static func writeRoot(_ text: String, to path: String, mode: Int) throws {
        try writeRoot(Data(text.utf8), to: path, mode: mode)
    }

    static func writeRoot(_ data: Data, to path: String, mode: Int) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let temp = path + ".tmp"
        try? fm.removeItem(atPath: temp)
        guard fm.createFile(atPath: temp, contents: data, attributes: [.posixPermissions: mode, .ownerAccountID: 0, .groupOwnerAccountID: 0]) else {
            throw ActionError("cannot write \(path)")
        }
        try? fm.removeItem(atPath: path)
        try fm.moveItem(atPath: temp, toPath: path)
    }
}
