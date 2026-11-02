import Foundation

/// Split DNS through `/etc/resolver/<domain>` files: macOS sends queries for a
/// domain to the servers in its file, whichever resolver is primary. The files
/// are static, so they are written once with an administrator's approval.
public enum ResolverFiles {
    public static let directory = "/etc/resolver"
    public static let marker = "# Managed by VPN Widget"

    public enum Status: Equatable, Sendable {
        case installed
        case outOfDate
        case notInstalled
        /// A file exists that the widget did not write. It is left alone.
        case foreign
    }

    /// Lowercases and trims a domain; nil when it cannot be a file name.
    public static func normalizeDomain(_ raw: String) -> String? {
        let d = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        guard !d.isEmpty, !d.contains("/"), !d.contains(" "), d.count < 254 else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
        guard d.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return d
    }

    /// An IPv4 or IPv6 address literal.
    public static func isServer(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return false }
        var v4 = in_addr()
        var v6 = in6_addr()
        return inet_pton(AF_INET, s, &v4) == 1 || inet_pton(AF_INET6, s, &v6) == 1
    }

    /// The file for each domain any profile claims. Servers of all profiles that
    /// claim a domain are merged in profile order.
    public static func render(profiles: [VPNProfile]) -> [String: String] {
        var servers: [String: [String]] = [:]
        var order: [String] = []
        for p in profiles {
            let own = p.dnsServers.map { $0.trimmingCharacters(in: .whitespaces) }.filter(isServer)
            guard !own.isEmpty else { continue }
            for raw in p.dnsDomains {
                guard let d = normalizeDomain(raw) else { continue }
                if servers[d] == nil { order.append(d) }
                for s in own where !(servers[d, default: []].contains(s)) {
                    servers[d, default: []].append(s)
                }
            }
        }
        var out: [String: String] = [:]
        for d in order {
            out[d] = ([marker] + servers[d, default: []].map { "nameserver \($0)" }).joined(separator: "\n") + "\n"
        }
        return out
    }

    public static func status(expected: String?, actual: String?) -> Status {
        switch (expected, actual) {
        case (nil, nil): return .notInstalled
        case (nil, .some(let a)): return a.contains(marker) ? .outOfDate : .foreign
        case (.some, nil): return .notInstalled
        case (.some(let e), .some(let a)):
            guard a.contains(marker) else { return .foreign }
            return e == a ? .installed : .outOfDate
        }
    }

    /// The shell script that installs staged files and removes the managed
    /// ones that are no longer wanted. It runs as root; it never touches a file
    /// without the marker.
    public static func applyScript(stageDirectory: String, install: [String], remove: [String]) -> String {
        var lines = [
            "set -e",
            "umask 022",
            "/usr/bin/install -d -m 755 -o root -g wheel \(shellQuote(directory))",
        ]
        for d in remove.sorted() {
            let path = shellQuote("\(directory)/\(d)")
            lines.append("if [ -f \(path) ] && /usr/bin/grep -q \(shellQuote(marker)) \(path); then /bin/rm -f \(path); fi")
        }
        for d in install.sorted() {
            let src = shellQuote("\(stageDirectory)/\(d)")
            let dst = shellQuote("\(directory)/\(d)")
            lines.append("if [ -f \(dst) ] && ! /usr/bin/grep -q \(shellQuote(marker)) \(dst); then echo \(shellQuote("refusing to overwrite \(directory)/\(d)")) >&2; exit 3; fi")
            lines.append("/usr/bin/install -m 644 -o root -g wheel \(src) \(dst)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
