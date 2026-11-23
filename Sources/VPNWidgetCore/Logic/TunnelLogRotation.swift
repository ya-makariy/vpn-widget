import Foundation

/// The rules of log rotation: once a day, at midnight local time, the log is
/// set aside under the day it covers and compressed, and archives older than
/// the tunnel's retention are deleted. The daemon does the file work.
public enum TunnelLogRotation {
    /// The day a moment falls on, as archives are named: 2026-11-16.
    public static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Whether a log last written at `modified` belongs to a day before `now`.
    public static func isDue(modified: Date, now: Date, calendar: Calendar = .current) -> Bool {
        day(modified, calendar: calendar) < day(now, calendar: calendar)
    }

    /// Where a day's log is set aside before it is compressed. `sequence`
    /// tells apart several archives of one day.
    public static func archivePath(name: String, day: String, sequence: Int = 1) -> String {
        "\(TunnelFiles.logDirectory)/\(name).\(day)\(sequence > 1 ? "-\(sequence)" : "").log"
    }

    public static let compressedSuffix = ".gz"

    /// The day in an archive's file name, compressed or not; nil for the live
    /// log, other tunnels' files and anything else in the directory.
    public static func archiveDay(fileName: String, name: String) -> String? {
        var rest = Substring(fileName)
        if rest.hasSuffix(compressedSuffix) { rest = rest.dropLast(compressedSuffix.count) }
        guard rest.hasPrefix(name + "."), rest.hasSuffix(".log") else { return nil }
        rest = rest.dropFirst(name.count + 1).dropLast(".log".count)
        let day = rest.prefix(10)
        let sequence = rest.dropFirst(10)
        guard day.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil,
              sequence.isEmpty || sequence.range(of: "^-[0-9]+$", options: .regularExpression) != nil
        else { return nil }
        return String(day)
    }

    /// The archives to delete: those of days more than `keepDays` before today.
    /// With 7, on the 16th the logs of the 9th to the 15th stay.
    public static func expired(fileNames: [String], name: String, now: Date, keepDays: Int, calendar: Calendar = .current) -> [String] {
        guard let oldest = calendar.date(byAdding: .day, value: -max(keepDays, 1), to: now) else { return [] }
        let cutoff = day(oldest, calendar: calendar)
        return fileNames.filter { file in
            archiveDay(fileName: file, name: name).map { $0 < cutoff } ?? false
        }.sorted()
    }
}

extension TunnelConfig.LogLevel {
    /// The level of a line a tool printed. openfortivpn says it itself, and
    /// its packet traces count as TRACE; openconnect does not, so its lines
    /// are INFO unless they speak of an error.
    public static func ofToolLine(_ line: String) -> TunnelConfig.LogLevel {
        let text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("ERROR:") { return .error }
        if text.hasPrefix("WARN:") || text.hasPrefix("INFO:") { return .info }
        if text.hasPrefix("DEBUG:") {
            return text.contains("--->") || text.contains("<---") ? .trace : .debug
        }
        let lower = text.lowercased()
        return lower.contains("error") || lower.contains("fail") ? .error : .info
    }

    /// Extra verbosity flags for the tool. openfortivpn always runs with one
    /// `-v`: the daemon reads addresses and DNS from its DEBUG lines, and
    /// drops them from the log itself below DEBUG.
    public func toolArguments(_ kind: TunnelConfig.Kind) -> [String] {
        switch (kind, self) {
        case (.openfortivpn, .trace): ["-v", "-v"]
        case (.openfortivpn, _): ["-v"]
        case (.openconnect, .debug): ["-v"]
        case (.openconnect, .trace): ["-v", "-v"]
        case (.openconnect, _): []
        // amneziawg-go takes its level from the environment; see Drivers.
        case (.amneziawg, _): []
        }
    }
}
