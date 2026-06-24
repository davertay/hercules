import Dependencies
import DependenciesMacros
import Foundation

/// Reads and writes the global ``AppConfig``. The live value touches `~/.hercules/config.json`; the
/// test value keeps the config in memory so tests can drive it through `withDependencies`.
@DependencyClient
public struct AppConfigClient: Sendable {
    /// Loads the persisted config, falling back to defaults. Tolerant — never throws.
    public var load: @Sendable () -> AppConfig = { AppConfig() }
    /// Persists the config to disk.
    public var save: @Sendable (_ config: AppConfig) throws -> Void
}

extension AppConfigClient: DependencyKey {
    public static let liveValue = AppConfigClient(
        load: { AppConfig.load() },
        save: { try $0.save() }
    )

    public static var testValue: AppConfigClient {
        let storage = LockIsolated(AppConfig())
        return AppConfigClient(
            load: { storage.value },
            save: { storage.setValue($0) }
        )
    }
}

extension DependencyValues {
    public var appConfigClient: AppConfigClient {
        get { self[AppConfigClient.self] }
        set { self[AppConfigClient.self] = newValue }
    }
}
