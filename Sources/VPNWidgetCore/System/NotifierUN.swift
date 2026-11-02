import Foundation
import UserNotifications

/// Desktop notifications. From an app bundle they go through the notification
/// center; a bare binary, or a bundle that is refused, falls back to
/// `osascript`. A failure is logged and the widget carries on.
public actor NotifierUN: Notifier {
    private var authorized: Bool?

    public init() {}

    public func send(_ notice: Notice) async {
        if Bundle.main.bundleIdentifier != nil, await authorize() {
            let content = UNMutableNotificationContent()
            content.title = notice.summary
            content.body = notice.body
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            do {
                try await UNUserNotificationCenter.current().add(request)
                return
            } catch {
                NSLog("notification: %@", error.localizedDescription)
            }
        }
        await Self.fallback(notice)
    }

    private func authorize() async -> Bool {
        if let authorized { return authorized }
        do {
            let ok = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            authorized = ok
            return ok
        } catch {
            NSLog("notification authorization: %@", error.localizedDescription)
            authorized = false
            return false
        }
    }

    static func fallback(_ notice: Notice) async {
        let script = "display notification \(appleScriptQuote(notice.body)) with title \"VPN Widget\" subtitle \(appleScriptQuote(notice.summary))"
        _ = try? await runProcess("/usr/bin/osascript", ["-e", script])
    }

    static func appleScriptQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// Runs a program to completion and returns its exit status and output.
@discardableResult
func runProcess(_ path: String, _ arguments: [String]) async throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    return try await withCheckedThrowingContinuation { c in
        process.terminationHandler = { p in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            c.resume(returning: (p.terminationStatus, String(decoding: data, as: UTF8.self)))
        }
        do {
            try process.run()
        } catch {
            c.resume(throwing: error)
        }
    }
}
