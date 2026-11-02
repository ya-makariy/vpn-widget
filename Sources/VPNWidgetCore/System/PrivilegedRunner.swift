import Foundation

/// Runs a shell script as root after the system's administrator prompt, through
/// `do shell script … with administrator privileges`. The script is the only
/// thing that runs privileged; everything it needs is staged beforehand.
@MainActor
public enum PrivilegedRunner {
    public static func run(_ script: String) throws {
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
