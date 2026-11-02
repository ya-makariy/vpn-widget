import Foundation

/// Bytes over a tunnel since it came up.
public struct Traffic: Equatable, Sendable {
    public var bytesIn: UInt64
    public var bytesOut: UInt64

    public init(bytesIn: UInt64, bytesOut: UInt64) {
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }

    public var description: String {
        "received \(formatBytes(bytesIn)) · sent \(formatBytes(bytesOut))"
    }
}

public func formatBytes(_ n: UInt64) -> String {
    let unit: Double = 1024
    if n < 1024 { return "\(n) B" }
    var value = Double(n) / unit
    var prefix = 0
    let prefixes: [Character] = ["K", "M", "G", "T", "P"]
    while value >= unit, prefix < prefixes.count - 1 {
        value /= unit
        prefix += 1
    }
    return String(format: "%.1f %@iB", value, String(prefixes[prefix]))
}

public func formatUptime(_ interval: TimeInterval) -> String {
    let s = Int64(max(interval, 0))
    switch s {
    case ..<60: return "\(s)s"
    case ..<3600: return "\(s / 60)m"
    case ..<86400: return "\(s / 3600)h \(s % 3600 / 60)m"
    default: return "\(s / 86400)d \(s % 86400 / 3600)h"
    }
}
