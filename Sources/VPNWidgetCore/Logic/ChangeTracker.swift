import Foundation

/// One desktop notification.
public struct Notice: Equatable, Sendable {
    public var summary: String
    public var body: String

    public init(summary: String, body: String = "") {
        self.summary = summary
        self.body = body
    }
}

/// Turns a stream of snapshots into the changes between them. The first
/// snapshot only sets the baseline, so that a restart notifies about nothing.
public struct ChangeTracker: Sendable {
    private var previous: Snapshot?

    public init() {}

    public mutating func next(_ snapshot: Snapshot) -> [Notice] {
        defer { previous = snapshot }
        guard let previous else { return [] }
        return changes(from: previous, to: snapshot)
    }
}

/// What differs between two snapshots, by profile.
public func changes(from prev: Snapshot, to cur: Snapshot) -> [Notice] {
    let before = Dictionary(prev.profiles.map { ($0.id, stateKey($0)) }, uniquingKeysWith: { a, _ in a })
    var out: [Notice] = []
    for p in cur.profiles {
        guard let old = before[p.id], old != stateKey(p) else { continue }
        out.append(notice(for: p))
    }
    return out
}

/// What counts as a VPN's state. Latency and traffic change on every poll, so
/// they are left out. A doubtful failure counts as ok, so that a short drop
/// notifies about nothing.
func stateKey(_ p: ProfileState) -> String {
    var key = p.state.text
    if p.checked { key += "|" + resultKey(p.result) }
    return key
}

func resultKey(_ r: CheckResult) -> String {
    if r.ok || r.doubtful { return "ok" }
    if !r.dns.isEmpty, r.dns != "ok" { return "DNS " + r.dns }
    return r.http
}

func notice(for p: ProfileState) -> Notice {
    let summary = p.profile.displayName + ": " + p.statusText
    guard p.checked else { return Notice(summary: summary) }
    return Notice(summary: summary, body: p.result.description)
}
