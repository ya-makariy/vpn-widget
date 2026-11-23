import Foundation

/// The service check URL as typed in a form. The checker takes only http and
/// https URLs with a host, so the forms accept nothing else.
public enum CheckURL {
    public enum Parsed: Equatable, Sendable {
        /// Empty text: the profile has no check.
        case none
        case url(URL)
        case invalid

        public var isValid: Bool { self != .invalid }

        public var url: URL? {
            if case .url(let url) = self { return url }
            return nil
        }
    }

    /// Trims the text and reads it as a URL. Text without a scheme, such as
    /// `service.example.com` or `host:8443/path`, gets `https://`.
    public static func parse(_ text: String) -> Parsed {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return .none }
        guard !s.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains) else { return .invalid }
        let typedScheme = hasScheme(s)
        guard let url = URL(string: typedScheme ? s : "https://" + s),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { return .invalid }
        // `mailto:user@example.com` is not a host with a port.
        if !typedScheme, url.user != nil { return .invalid }
        return .url(url)
    }

    /// Whether the text starts with `scheme://`. A lone colon does not count:
    /// in `host:8443/path` it separates the port.
    private static func hasScheme(_ s: String) -> Bool {
        guard let separator = s.range(of: "://") else { return false }
        let scheme = s[..<separator.lowerBound]
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+-."))
        guard let first = scheme.unicodeScalars.first, CharacterSet.letters.contains(first) else { return false }
        return scheme.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
    }
}
