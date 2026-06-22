import Dependencies
import Foundation
import Testing

@testable import Agent

@Suite("AppConfig")
struct AppConfigTests {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appending(component: UUID().uuidString)
            .appending(component: "config.json")
    }

    @Test func roundTripsThroughEncodeDecode() throws {
        let config = AppConfig(
            agentExecutablePath: "/path/to/claude",
            extraArguments: [
                ExtraArgument(flag: "--some-flag", value: "some-value"),
                ExtraArgument(flag: "--other-flag", value: nil),
            ]
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded == config)
    }

    @Test func preservesExtraArgumentOrder() throws {
        let config = AppConfig(extraArguments: [
            ExtraArgument(flag: "--a", value: "1"),
            ExtraArgument(flag: "--b", value: "2"),
            ExtraArgument(flag: "--c", value: nil),
        ])
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.extraArguments.map(\.flag) == ["--a", "--b", "--c"])
    }

    @Test func decodesPathOnlyDocument() throws {
        let json = Data(#"{ "agentExecutablePath": "/usr/local/bin/claude" }"#.utf8)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: json)
        #expect(decoded.agentExecutablePath == "/usr/local/bin/claude")
        #expect(decoded.extraArguments.isEmpty)
    }

    @Test func decodesArgumentsOnlyDocument() throws {
        let json = Data(#"{ "extraArguments": [ { "flag": "--x", "value": null } ] }"#.utf8)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: json)
        #expect(decoded.agentExecutablePath == nil)
        #expect(decoded.extraArguments == [ExtraArgument(flag: "--x", value: nil)])
    }

    @Test func treatsEmptyPathAsNotConfigured() throws {
        let json = Data(#"{ "agentExecutablePath": "   " }"#.utf8)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: json)
        #expect(decoded.agentExecutablePath == nil)
    }

    @Test func loadOfMissingFileYieldsDefaults() {
        let config = AppConfig.load(from: tempFile())
        #expect(config == AppConfig())
    }

    @Test func loadOfEmptyFileYieldsDefaults() throws {
        let url = tempFile()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: url)
        #expect(AppConfig.load(from: url) == AppConfig())
    }

    @Test func loadOfMalformedFileYieldsDefaults() throws {
        let url = tempFile()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not json {".utf8).write(to: url)
        #expect(AppConfig.load(from: url) == AppConfig())
    }

    @Test func saveCreatesDirectoryAndRoundTrips() throws {
        let url = tempFile()
        let config = AppConfig(
            agentExecutablePath: "/path/to/claude",
            extraArguments: [ExtraArgument(flag: "--some-flag", value: "some-value")]
        )
        try config.save(to: url)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(AppConfig.load(from: url) == config)
    }

    @Test func saveProducesPrettyKeyOrderedJSON() throws {
        let url = tempFile()
        let config = AppConfig(
            agentExecutablePath: "/path/to/claude",
            extraArguments: [
                ExtraArgument(flag: "--some-flag", value: "some-value"),
                ExtraArgument(flag: "--other-flag", value: nil),
            ]
        )
        try config.save(to: url)
        let json = try String(contentsOf: url, encoding: .utf8)
        let expected = """
        {
          "agentExecutablePath" : "/path/to/claude",
          "extraArguments" : [
            {
              "flag" : "--some-flag",
              "value" : "some-value"
            },
            {
              "flag" : "--other-flag",
              "value" : null
            }
          ]
        }
        """
        #expect(json == expected)
    }
}

@Suite("AppConfigClient")
struct AppConfigClientTests {
    @Test func testValueRoundTripsInMemory() throws {
        try withDependencies {
            $0.appConfigClient = .testValue
        } operation: {
            @Dependency(\.appConfigClient) var client
            #expect(client.load() == AppConfig())

            let config = AppConfig(
                agentExecutablePath: "/path/to/claude",
                extraArguments: [ExtraArgument(flag: "--x", value: "y")]
            )
            try client.save(config)
            #expect(client.load() == config)
        }
    }

    @Test func overrideDrivesLoad() {
        let stub = AppConfig(agentExecutablePath: "/stub/claude")
        withDependencies {
            $0.appConfigClient.load = { stub }
        } operation: {
            @Dependency(\.appConfigClient) var client
            #expect(client.load() == stub)
        }
    }
}
