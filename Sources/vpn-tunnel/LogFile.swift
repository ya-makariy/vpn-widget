import Foundation
import VPNWidgetCore

/// The daemon's log. launchd points stdout at the file; this takes it over,
/// so that the file can be set aside at midnight without restarting the
/// tunnel: the day's log is renamed, compressed, and old archives deleted.
/// A tunnel that was not running at midnight rotates at its next start.
final class LogFile: @unchecked Sendable {
    let name: String
    let level: TunnelConfig.LogLevel
    let keepDays: Int
    private let path: String
    private let lock = NSLock()
    private var currentDay: String
    private var timer: DispatchSourceTimer?
    private let work = DispatchQueue(label: "com.ya-makariy.vpn-widget.log")

    init(name: String, level: TunnelConfig.LogLevel, keepDays: Int) {
        self.name = name
        self.level = level
        self.keepDays = keepDays
        path = TunnelFiles.logPath(name)
        currentDay = TunnelLogRotation.day(Date())
    }

    /// Rotates a log left from an earlier day, then checks the date twice a
    /// minute: a timer set for midnight would be thrown off by sleep.
    func start() {
        let now = Date()
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        if let modified = attributes?[.modificationDate] as? Date, (attributes?[.size] as? NSNumber)?.intValue ?? 0 > 0,
           TunnelLogRotation.isDue(modified: modified, now: now) {
            lock.withLock { rotate(archiveDay: TunnelLogRotation.day(modified)) }
        } else {
            lock.withLock { redirect() }
            work.async { self.prune() }
        }
        let timer = DispatchSource.makeTimerSource(queue: work)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in self?.rotateIfNewDay() }
        timer.resume()
        self.timer = timer
    }

    func write(_ text: String, level line: TunnelConfig.LogLevel) {
        guard level.includes(line) else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        lock.withLock {
            print("\(stamp) \(text)")
            fflush(stdout)
        }
    }

    private func rotateIfNewDay() {
        let today = TunnelLogRotation.day(Date())
        lock.withLock {
            guard today != currentDay else { return }
            let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.intValue ?? 0
            if size > 0 { rotate(archiveDay: currentDay) }
            currentDay = today
        }
    }

    /// Called with the lock held: no line is written between the rename and
    /// the new file taking over stdout.
    private func rotate(archiveDay: String) {
        let fm = FileManager.default
        var sequence = 1
        var archive = TunnelLogRotation.archivePath(name: name, day: archiveDay)
        while fm.fileExists(atPath: archive) || fm.fileExists(atPath: archive + TunnelLogRotation.compressedSuffix) {
            sequence += 1
            archive = TunnelLogRotation.archivePath(name: name, day: archiveDay, sequence: sequence)
        }
        fflush(stdout)
        let moved = rename(path, archive) == 0
        redirect()
        work.async {
            if moved { self.compress(archive) }
            self.prune()
        }
    }

    /// Points stdout and stderr at the log file, creating it when needed.
    private func redirect() {
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        fchmod(fd, 0o644)
        fflush(stdout)
        dup2(fd, STDOUT_FILENO)
        dup2(fd, STDERR_FILENO)
        close(fd)
    }

    private func compress(_ archive: String) {
        let gzip = Process()
        gzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        gzip.arguments = ["-f", archive]
        gzip.standardOutput = FileHandle.nullDevice
        gzip.standardError = FileHandle.nullDevice
        do {
            try gzip.run()
            gzip.waitUntilExit()
            if gzip.terminationStatus != 0 { write("log: gzip of \(archive) failed (\(gzip.terminationStatus))", level: .error) }
        } catch {
            write("log: cannot compress \(archive): \(error.localizedDescription)", level: .error)
        }
    }

    private func prune() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(atPath: TunnelFiles.logDirectory)) ?? []
        for file in TunnelLogRotation.expired(fileNames: files, name: name, now: Date(), keepDays: keepDays) {
            try? fm.removeItem(atPath: "\(TunnelFiles.logDirectory)/\(file)")
        }
    }
}
