import Foundation

/// Reading a tunnel's log: the end of it, since a tunnel that has been
/// retrying for a week writes far more than anyone wants on screen.
public enum TunnelLog {
    /// How much of the end of the file the window shows.
    public static let defaultTailBytes = 256 * 1024

    public struct Tail: Equatable, Sendable {
        /// The text read, starting at the beginning of a line.
        public var text: String
        /// The size of the file when it was read: where to read on from.
        public var fileSize: UInt64
        /// Whether the file holds more than `text`.
        public var truncated: Bool

        public init(text: String, fileSize: UInt64, truncated: Bool) {
            self.text = text
            self.fileSize = fileSize
            self.truncated = truncated
        }
    }

    /// The last `maxBytes` of the file, from the first whole line in them.
    /// Nil when there is no file: the tunnel has not been started yet.
    public static func tail(path: String, maxBytes: Int = defaultTailBytes) -> Tail? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, var data = try? handle.readToEnd() else {
            return Tail(text: "", fileSize: size, truncated: false)
        }
        let end = start + UInt64(data.count)
        if start > 0 {
            // The cut lands in the middle of a line; start at the next one.
            if let newline = data.firstIndex(of: 0x0A) {
                data = data.subdata(in: data.index(after: newline)..<data.endIndex)
            } else {
                data = Data()
            }
        }
        return Tail(text: String(decoding: data, as: UTF8.self), fileSize: end, truncated: start > 0)
    }

    /// What was appended after `offset`, and the new offset. A file that got
    /// shorter was replaced; it is read again from its start.
    public static func read(path: String, from offset: UInt64) -> (text: String, offset: UInt64)? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size < offset ? 0 : offset
        guard size > start, (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else {
            return ("", start)
        }
        return (String(decoding: data, as: UTF8.self), start + UInt64(data.count))
    }

    /// The last `count` lines of a text.
    public static func lastLines(_ text: String, _ count: Int) -> String {
        guard count > 0 else { return "" }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let body = lines.last == "" ? lines.dropLast() : lines[...]
        return body.suffix(count).joined(separator: "\n")
    }
}
