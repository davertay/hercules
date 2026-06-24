import Agent
import Dependencies
import Foundation
import Observation

/// Backs ``SettingsView``. Loads the persisted ``AppConfig`` on appear and writes it back through
/// ``AppConfigClient`` on every visible mutation — field commit, row add, and row delete — so the
/// on-disk config always reflects what the user sees.
@MainActor
@Observable
public final class SettingsModel {
    /// The Agent executable path, as typed. Empty means "not configured".
    public var agentExecutablePath: String = ""
    /// The Extra Arguments rows, in display order. Identity is per-row so editing one field doesn't
    /// disturb the others as the list mutates.
    public var arguments: [ArgumentRow] = []

    @ObservationIgnored
    @Dependency(\.appConfigClient) private var appConfigClient

    public init() {}

    /// Populates the fields from the persisted config. First open with no file yields empty defaults.
    public func load() {
        let config = appConfigClient.load()
        agentExecutablePath = config.agentExecutablePath ?? ""
        arguments = config.extraArguments.map(ArgumentRow.init)
    }

    /// Appends a blank argument row and persists.
    public func addArgument() {
        arguments.append(ArgumentRow())
        save()
    }

    /// Removes the given row and persists.
    public func deleteArgument(_ row: ArgumentRow) {
        arguments.removeAll { $0.id == row.id }
        save()
    }

    /// Writes the current visible state back through ``AppConfigClient``. Called on every mutation;
    /// swallows write errors, matching the tolerant read path. Rows with a blank flag are dropped
    /// from the persisted projection — mirroring `Harness.renderArgs`, which skips them at render
    /// time — so a freshly-added (or half-typed) row never lands on disk. The in-memory `arguments`
    /// array is left untouched so that blank row stays editable in the form.
    public func save() {
        let trimmed = agentExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let config = AppConfig(
            agentExecutablePath: trimmed.isEmpty ? nil : trimmed,
            extraArguments: arguments
                .filter { !$0.flag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .map(\.extraArgument)
        )
        try? appConfigClient.save(config)
    }
}

/// One editable Extra Arguments row. Carries a stable identity for the SwiftUI list and an empty
/// `value` stands in for a bare flag (mapped back to `nil` when persisted).
public struct ArgumentRow: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var flag: String
    public var value: String

    public init(id: UUID = UUID(), flag: String = "", value: String = "") {
        self.id = id
        self.flag = flag
        self.value = value
    }

    init(_ argument: ExtraArgument) {
        self.init(flag: argument.flag, value: argument.value ?? "")
    }

    var extraArgument: ExtraArgument {
        ExtraArgument(flag: flag, value: value.isEmpty ? nil : value)
    }
}
