import Foundation

/// Marks a failed check as doubtful until it has failed for longer than the
/// grace in a row. A dropped request or two is common and not worth an alarm.
public struct FailureTracker: Sendable {
    public var failGrace: TimeInterval
    /// Since when each check, by key, has failed in a row.
    private var failing: [String: Date] = [:]

    public init(failGrace: TimeInterval = 10) {
        self.failGrace = failGrace
    }

    public mutating func confirm(key: String, result: CheckResult, now: Date) -> CheckResult {
        var r = result
        if r.ok {
            failing[key] = nil
            return r
        }
        let since = failing[key] ?? now
        failing[key] = since
        r.doubtful = now.timeIntervalSince(since) <= failGrace
        return r
    }

    /// Drops a check's failure count, as when its tunnel has gone.
    public mutating func forget(key: String) {
        failing[key] = nil
    }
}
