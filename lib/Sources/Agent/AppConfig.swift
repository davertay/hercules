import Foundation

/// One extra argument forwarded to the agent harness: a `flag` and an optional `value`. A `nil` value
/// models a bare flag (encoded as an explicit `null` to keep the on-disk shape stable).
public struct ExtraArgument: Codable, Equatable, Sendable {
    public var flag: String
    public var value: String?

    public init(flag: String, value: String? = nil) {
        self.flag = flag
        self.value = value
    }

    private enum CodingKeys: String, CodingKey {
        case flag
        case value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(flag, forKey: .flag)
        // Encode `nil` as an explicit `null` rather than omitting the key, matching the schema.
        try container.encode(value, forKey: .value)
    }
}

/// The persisted, global app configuration backing `~/.hercules/config.json`.
///
/// Decoding is tolerant: a missing key falls back to its default, and an empty/whitespace
/// `agentExecutablePath` is treated as "not configured" (`nil`).
public struct AppConfig: Codable, Equatable, Sendable {
    /// The agent executable path. `nil` (omitted or empty on disk) means "not configured".
    public var agentExecutablePath: String?
    /// Extra arguments forwarded to the harness, in order.
    public var extraArguments: [ExtraArgument]

    public init(agentExecutablePath: String? = nil, extraArguments: [ExtraArgument] = []) {
        self.agentExecutablePath = agentExecutablePath
        self.extraArguments = extraArguments
    }

    private enum CodingKeys: String, CodingKey {
        case agentExecutablePath
        case extraArguments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let path = try container.decodeIfPresent(String.self, forKey: .agentExecutablePath)
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.agentExecutablePath = (trimmed?.isEmpty ?? true) ? nil : trimmed
        self.extraArguments = try container.decodeIfPresent([ExtraArgument].self, forKey: .extraArguments) ?? []
    }
}

extension AppConfig {
    /// `~/.hercules/config.json`, a sibling of the Workflows root directory.
    public static func defaultFile() -> URL {
        URL.homeDirectory.appending(path: ".hercules/config.json")
    }

    /// Reads the config at `url`. A missing, empty, or malformed file yields defaults; never throws.
    public static func load(from url: URL = defaultFile()) -> AppConfig {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return AppConfig() }
        return (try? JSONDecoder().decode(AppConfig.self, from: data)) ?? AppConfig()
    }

    /// Writes pretty-printed, key-ordered JSON to `url`, creating the parent directory if needed.
    public func save(to url: URL = AppConfig.defaultFile()) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url)
    }
}
