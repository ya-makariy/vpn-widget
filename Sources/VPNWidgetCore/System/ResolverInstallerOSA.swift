import Foundation

/// Writes the `/etc/resolver` files with the administrator's approval, through
/// one `do shell script … with administrator privileges`. Files are staged in
/// Application Support first, so the privileged step only copies.
@MainActor
public enum ResolverInstaller {
    public static func currentContents(domain: String) -> String? {
        try? String(contentsOfFile: "\(ResolverFiles.directory)/\(domain)", encoding: .utf8)
    }

    /// The status of every domain that is wanted or was managed.
    public static func statuses(rendered: [String: String], managed: [String]) -> [String: ResolverFiles.Status] {
        var out: [String: ResolverFiles.Status] = [:]
        for d in Set(rendered.keys).union(managed) {
            out[d] = ResolverFiles.status(expected: rendered[d], actual: currentContents(domain: d))
        }
        return out
    }

    /// Whether the files on disk match what the profiles want.
    public static func isUpToDate(rendered: [String: String], managed: [String]) -> Bool {
        statuses(rendered: rendered, managed: managed).allSatisfy { d, s in
            rendered[d] == nil ? (s == .notInstalled || s == .foreign) : s == .installed
        }
    }

    /// Installs the rendered files and removes managed ones that are no longer
    /// wanted. Returns the new list of managed domains.
    public static func apply(rendered: [String: String], managed: [String], stageDirectory: URL = ProfileStoreJSON.supportDirectory.appendingPathComponent("resolver-stage", isDirectory: true)) throws -> [String] {
        for (d, _) in rendered where ResolverFiles.status(expected: rendered[d], actual: currentContents(domain: d)) == .foreign {
            throw ActionError("/etc/resolver/\(d) exists and was not written by VPN Widget; remove it by hand first")
        }
        let fm = FileManager.default
        try? fm.removeItem(at: stageDirectory)
        try fm.createDirectory(at: stageDirectory, withIntermediateDirectories: true)
        for (d, content) in rendered {
            try content.write(to: stageDirectory.appendingPathComponent(d), atomically: true, encoding: .utf8)
        }
        let remove = managed.filter { rendered[$0] == nil }
        let script = ResolverFiles.applyScript(stageDirectory: stageDirectory.path, install: Array(rendered.keys), remove: remove)
        try runPrivileged(script)
        try? fm.removeItem(at: stageDirectory)
        return rendered.keys.sorted()
    }

    /// Removes every managed file.
    public static func removeAll(managed: [String]) throws {
        guard !managed.isEmpty else { return }
        try runPrivileged(ResolverFiles.applyScript(stageDirectory: "/nonexistent", install: [], remove: managed))
    }

    private static func runPrivileged(_ script: String) throws {
        let source = "do shell script \(NotifierUN.appleScriptQuote(script)) with administrator privileges"
        guard let apple = NSAppleScript(source: source) else { throw ActionError("cannot build the script") }
        var error: NSDictionary?
        apple.executeAndReturnError(&error)
        if let error {
            let number = error[NSAppleScript.errorNumber] as? Int ?? 0
            if number == -128 { throw ActionError("cancelled") }
            let message = error[NSAppleScript.errorMessage] as? String ?? "error \(number)"
            throw ActionError(message)
        }
    }
}
