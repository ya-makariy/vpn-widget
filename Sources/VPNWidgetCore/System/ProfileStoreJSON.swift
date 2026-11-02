import Foundation

/// The profiles, as JSON in Application Support: versioned, readable in a bug
/// report, and editable by hand.
public struct ProfileStoreJSON: Sendable {
    public let url: URL

    public init(url: URL = ProfileStoreJSON.defaultURL) {
        self.url = url
    }

    public static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VPN Widget", isDirectory: true)
    }

    public static var defaultURL: URL {
        supportDirectory.appendingPathComponent("profiles.json")
    }

    public func load() throws -> StoredConfig {
        guard FileManager.default.fileExists(atPath: url.path) else { return StoredConfig() }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(StoredConfig.self, from: data)
    }

    public func save(_ config: StoredConfig) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var config = config
        config.version = StoredConfig.currentVersion
        try encoder.encode(config).write(to: url, options: .atomic)
    }
}
