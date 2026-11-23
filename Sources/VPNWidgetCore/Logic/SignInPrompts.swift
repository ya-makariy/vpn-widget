import Foundation

/// Remembers which sign-in page was last opened for each profile, so that a
/// page opens once per attempt. An attempt is a daemon run and its attempt
/// number: every run counts from one again, so the number alone would make
/// the first prompt after a restart look like one already shown.
public struct SignInPrompts: Sendable {
    private struct Prompt: Equatable, Sendable {
        var run: Int32
        var attempt: Int
    }

    private var opened: [String: Prompt] = [:]

    public init() {}

    /// Whether the page of this attempt has yet to be opened; saying so
    /// counts as opening it.
    public mutating func shouldOpen(key: String, run: Int32, attempt: Int) -> Bool {
        let prompt = Prompt(run: run, attempt: attempt)
        if opened[key] == prompt { return false }
        opened[key] = prompt
        return true
    }

    /// Drops what was opened, as when the tunnel is up or down.
    public mutating func forget(key: String) {
        opened[key] = nil
    }
}
