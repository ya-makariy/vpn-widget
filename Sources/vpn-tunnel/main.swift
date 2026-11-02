import Foundation
import VPNWidgetCore

// vpn-tunnel: the root side of the widget's own tunnels. launchd runs
// `vpn-tunnel run <name>` as a daemon per tunnel; the admin prompt runs
// `setup`, `install` and `remove`. Installed root-owned at
// /usr/local/libexec/vpn-widget/vpn-tunnel; see TunnelFiles for the paths.

let usage = """
usage: vpn-tunnel run <name>                         run the tunnel until TERM (launchd)
       vpn-tunnel setup <user> <homebrew prefix>     directories, tools, sudoers rule (root)
       vpn-tunnel install <name> <profile.json> [<secret file>]
       vpn-tunnel remove <name>
       vpn-tunnel status <name>                      print the state file
"""

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    FileHandle.standardError.write(usage.data(using: .utf8)!)
    exit(2)
}

do {
    switch (command, arguments.count) {
    case ("run", 2):
        try Admin.requireRoot()
        let runner = try TunnelRunner(name: arguments[1])
        exit(runner.run())
    case ("setup", 3):
        try Admin.requireRoot()
        try Admin.setup(user: arguments[1], homebrewPrefix: arguments[2])
    case ("install", 3), ("install", 4):
        try Admin.requireRoot()
        try Admin.install(name: arguments[1], stagedConfig: arguments[2], stagedSecret: arguments.count == 4 ? arguments[3] : nil)
    case ("remove", 2):
        try Admin.requireRoot()
        try Admin.remove(name: arguments[1])
    case ("status", 2):
        if let state = TunnelControllerLaunchd.readState(arguments[1]) {
            print(String(decoding: try TunnelState.encoder.encode(state), as: UTF8.self))
        } else {
            print("no state file")
        }
    default:
        FileHandle.standardError.write(usage.data(using: .utf8)!)
        exit(2)
    }
} catch {
    FileHandle.standardError.write("vpn-tunnel: \(error)\n".data(using: .utf8)!)
    exit(1)
}
