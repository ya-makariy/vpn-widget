import Foundation
import VPNWidgetCore

enum Format {
    static func bytes(_ n: UInt64) -> String { formatBytes(n) }

    static func uptime(since: Date, now: Date) -> String { formatUptime(now.timeIntervalSince(since)) }

    static func milliseconds(_ ms: Int) -> String { "\(ms) ms" }
}
