import Agent
import Dependencies
import Testing

@testable import HerculesApp

@MainActor
@Suite("SettingsModel")
struct SettingsModelTests {

    // MARK: - Loading

    @Test func loadPopulatesFieldsFromConfig() {
        let config = AppConfig(
            agentExecutablePath: "/usr/local/bin/claude",
            extraArguments: [
                ExtraArgument(flag: "--model", value: "claude-opus-4-8"),
                ExtraArgument(flag: "--verbose", value: nil),
            ]
        )

        let model = withDependencies {
            $0.appConfigClient.load = { config }
        } operation: {
            SettingsModel()
        }

        model.load()

        #expect(model.agentExecutablePath == "/usr/local/bin/claude")
        #expect(model.arguments.map(\.flag) == ["--model", "--verbose"])
        #expect(model.arguments.map(\.value) == ["claude-opus-4-8", ""])
    }

    @Test func firstOpenWithNoFileShowsEmptyDefaults() {
        let model = withDependencies {
            $0.appConfigClient = .testValue
        } operation: {
            SettingsModel()
        }

        model.load()

        #expect(model.agentExecutablePath == "")
        #expect(model.arguments.isEmpty)
    }

    // MARK: - List mutation

    @Test func addArgumentAppendsBlankRow() {
        let model = withDependencies {
            $0.appConfigClient = .testValue
        } operation: {
            SettingsModel()
        }

        model.addArgument()
        model.addArgument()

        #expect(model.arguments.count == 2)
        #expect(model.arguments.allSatisfy { $0.flag.isEmpty && $0.value.isEmpty })
    }

    @Test func deleteArgumentRemovesOnlyThatRow() {
        let model = withDependencies {
            $0.appConfigClient.load = {
                AppConfig(extraArguments: [
                    ExtraArgument(flag: "--a", value: nil),
                    ExtraArgument(flag: "--b", value: nil),
                    ExtraArgument(flag: "--c", value: nil),
                ])
            }
        } operation: {
            SettingsModel()
        }
        model.load()

        model.deleteArgument(model.arguments[1])

        #expect(model.arguments.map(\.flag) == ["--a", "--c"])
    }

    // MARK: - Persistence

    @Test func saveWritesVisibleStateThroughClient() throws {
        let saved = LockIsolated<AppConfig?>(nil)
        let model = withDependencies {
            $0.appConfigClient.load = { AppConfig() }
            $0.appConfigClient.save = { saved.setValue($0) }
        } operation: {
            SettingsModel()
        }

        model.agentExecutablePath = "  ~/.local/bin/claude  "
        model.arguments = [
            ArgumentRow(flag: "--model", value: "claude-opus-4-8"),
            ArgumentRow(flag: "--verbose", value: ""),
        ]
        model.save()

        let config = try #require(saved.value)
        // The path is trimmed and an empty value persists as a bare flag (`nil`).
        #expect(config.agentExecutablePath == "~/.local/bin/claude")
        #expect(config.extraArguments == [
            ExtraArgument(flag: "--model", value: "claude-opus-4-8"),
            ExtraArgument(flag: "--verbose", value: nil),
        ])
    }

    @Test func addAndDeletePersistThroughClient() throws {
        let saved = LockIsolated<AppConfig?>(nil)
        let model = withDependencies {
            $0.appConfigClient.load = { AppConfig() }
            $0.appConfigClient.save = { saved.setValue($0) }
        } operation: {
            SettingsModel()
        }

        // A blank row is added to the form but filtered out of the persisted projection.
        model.addArgument()
        #expect(model.arguments.count == 1)
        #expect(saved.value?.extraArguments.isEmpty == true)

        // Once the flag is typed and re-saved, the row persists.
        model.arguments[0].flag = "--verbose"
        model.save()
        #expect(saved.value?.extraArguments == [ExtraArgument(flag: "--verbose", value: nil)])

        model.deleteArgument(model.arguments[0])
        #expect(saved.value?.extraArguments.isEmpty == true)
    }

    @Test func addArgumentDoesNotPersistBlankRow() throws {
        let saved = LockIsolated<AppConfig?>(nil)
        let model = withDependencies {
            $0.appConfigClient.load = { AppConfig() }
            $0.appConfigClient.save = { saved.setValue($0) }
        } operation: {
            SettingsModel()
        }

        // Adding a row leaves an editable blank in the form...
        model.addArgument()
        #expect(model.arguments.count == 1)
        model.save()

        // ...but nothing empty reaches disk.
        #expect(saved.value?.extraArguments.isEmpty == true)
    }

    @Test func blankRowAddedThenFilledPersists() throws {
        let saved = LockIsolated<AppConfig?>(nil)
        let model = withDependencies {
            $0.appConfigClient.load = { AppConfig() }
            $0.appConfigClient.save = { saved.setValue($0) }
        } operation: {
            SettingsModel()
        }

        model.addArgument()
        model.arguments[0].flag = "--model"
        model.arguments[0].value = "claude-opus-4-8"
        model.save()

        #expect(saved.value?.extraArguments == [
            ExtraArgument(flag: "--model", value: "claude-opus-4-8")
        ])
    }

    @Test func whitespaceOnlyFlagIsNotPersisted() throws {
        let saved = LockIsolated<AppConfig?>(nil)
        let model = withDependencies {
            $0.appConfigClient.load = { AppConfig() }
            $0.appConfigClient.save = { saved.setValue($0) }
        } operation: {
            SettingsModel()
        }

        model.arguments = [
            ArgumentRow(flag: "--model", value: "claude-opus-4-8"),
            ArgumentRow(flag: "   ", value: "stray"),
        ]
        model.save()

        #expect(saved.value?.extraArguments == [
            ExtraArgument(flag: "--model", value: "claude-opus-4-8")
        ])
    }

    @Test func emptyPathPersistsAsNotConfigured() throws {
        let saved = LockIsolated<AppConfig?>(nil)
        let model = withDependencies {
            $0.appConfigClient.load = { AppConfig() }
            $0.appConfigClient.save = { saved.setValue($0) }
        } operation: {
            SettingsModel()
        }

        model.agentExecutablePath = "   "
        model.save()

        #expect(saved.value?.agentExecutablePath == nil)
    }
}
