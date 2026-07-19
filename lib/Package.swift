// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "HerculesApp",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HerculesApp", targets: ["HerculesApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/sqlite-data", exact: "1.7.0"),
        .package(url: "https://github.com/pointfreeco/swift-clocks", exact: "1.1.0"),
        .package(url: "https://github.com/pointfreeco/swift-custom-dump", exact: "1.6.1"),
        .package(url: "https://github.com/pointfreeco/swift-dependencies", exact: "1.14.1"),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", exact: "1.19.3"),
        .package(url: "https://github.com/pointfreeco/swift-structured-queries", exact: "0.33.2"),
        .package(url: "https://github.com/swiftlang/swift-subprocess", exact: "0.5.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", exact: "0.12.1"),
        .package(url: "https://github.com/gonzalezreal/textual", exact: "0.5.0"),
    ],
    targets: [
        .target(
            name: "Agent",
            dependencies: [
                "Store",
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesMacros", package: "swift-dependencies"),
                .product(name: "SQLiteData", package: "sqlite-data"),
                .product(name: "Subprocess", package: "swift-subprocess"),
            ]
        ),
        .testTarget(
            name: "AgentTests",
            dependencies: [
                "Agent",
                "Store",
                .product(name: "Clocks", package: "swift-clocks"),
                .product(name: "CustomDump", package: "swift-custom-dump"),
                .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
                .product(name: "SnapshotTestingCustomDump", package: "swift-snapshot-testing"),
                .product(name: "SQLiteData", package: "sqlite-data"),
                .product(name: "Subprocess", package: "swift-subprocess"),
            ],
            resources: [
                .copy("Fixtures"),
            ]
        ),
        .target(
            name: "Allocate",
            dependencies: [
                "Agent",
                "Chat",
                "DAGGraphUI",
                "Skills",
                "Store",
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ]
        ),
        .testTarget(
            name: "AllocateTests",
            dependencies: [
                "Allocate",
                "Agent",
                "Chat",
                "DAGGraphUI",
                "Skills",
                "Store",
                .product(name: "CustomDump", package: "swift-custom-dump"),
                .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ]
        ),
        .target(
            name: "Chat",
            dependencies: [
                "Agent",
                "Store",
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ]
        ),
        .testTarget(
            name: "ChatTests",
            dependencies: [
                "Chat",
                "Agent",
                "Store",
                .product(name: "CustomDump", package: "swift-custom-dump"),
                .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ]
        ),
        .target(
            name: "Design",
            dependencies: [
                "Agent",
                "Chat",
                "Skills",
                "Store",
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ]
        ),
        .testTarget(
            name: "DesignTests",
            dependencies: [
                "Design",
                "Skills",
                "Store",
                .product(name: "CustomDump", package: "swift-custom-dump"),
                .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ]
        ),
        .target(
            name: "HerculesApp",
            dependencies: [
                "Agent",
                "Allocate",
                "DAGGraphUI",
                "Design",
                "Execute",
                "IssueGraph",
                "IssueMCP",
                "Store",
                "TestChat",
                "Validate",
                "WorkflowContainer",
            ]
        ),
        .testTarget(
            name: "HerculesAppTests",
            dependencies: [
                "Agent",
                "HerculesApp",
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
            ]
        ),
        .target(
            name: "IssueMCP",
            dependencies: [
                "Store",
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ]
        ),
        .testTarget(
            name: "IssueMCPTests",
            dependencies: [
                "IssueMCP",
                "Store",
                .product(name: "CustomDump", package: "swift-custom-dump"),
                .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ]
        ),
        .target(
            name: "DAGGraphUI",
            dependencies: [
                "IssueGraph",
                "Store",
            ]
        ),
        .testTarget(
            name: "DAGGraphUITests",
            dependencies: [
                "DAGGraphUI",
            ]
        ),
        .target(
            name: "Execute",
            dependencies: [
                "Agent",
                "Chat",
                "DAGGraphUI",
                "IssueGraph",
                "Skills",
                "Store",
                "UISupport",
                "Worktree",
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ]
        ),
        .testTarget(
            name: "ExecuteTests",
            dependencies: [
                "Execute",
                "Agent",
                "IssueGraph",
                "Skills",
                "Store",
                "Worktree",
                .product(name: "Clocks", package: "swift-clocks"),
                .product(name: "CustomDump", package: "swift-custom-dump"),
                .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ]
        ),
        .target(
            name: "IssueGraph"
        ),
        .testTarget(
            name: "IssueGraphTests",
            dependencies: [
                "IssueGraph",
            ]
        ),
        .target(
            name: "Skills",
            resources: [
                .copy("Resources"),
            ]
        ),
        .testTarget(
            name: "SkillsTests",
            dependencies: [
                "Skills",
            ]
        ),
        .target(
            name: "UISupport",
            dependencies: [
                .product(name: "Textual", package: "textual"),
            ]
        ),
        .testTarget(
            name: "UISupportTests",
            dependencies: [
                "UISupport",
            ]
        ),
        .target(
            name: "Store",
            dependencies: [
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "SQLiteData", package: "sqlite-data"),
                .product(name: "StructuredQueries", package: "swift-structured-queries"),
            ]
        ),
        .testTarget(
            name: "StoreTests",
            dependencies: [
                "Store",
                .product(name: "CustomDump", package: "swift-custom-dump"),
                .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ]
        ),
        .target(
            name: "TestChat",
            dependencies: [
                "Agent",
                "Chat",
                "Store",
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ]
        ),
        .testTarget(
            name: "TestChatTests",
            dependencies: [
                "TestChat",
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ]
        ),
        .target(
            name: "Validate",
            dependencies: [
                "Agent",
                "Chat",
                "DAGGraphUI",
                "Skills",
                "Store",
                "UISupport",
                "Worktree",
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ]
        ),
        .testTarget(
            name: "ValidateTests",
            dependencies: [
                "Validate",
                "Agent",
                "Skills",
                "Store",
                "Worktree",
                .product(name: "CustomDump", package: "swift-custom-dump"),
                .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ]
        ),
        .target(
            name: "Worktree",
            dependencies: [
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesMacros", package: "swift-dependencies"),
            ]
        ),
        .testTarget(
            name: "WorktreeTests",
            dependencies: [
                "Worktree",
            ]
        ),
        .target(
            name: "WorkflowContainer",
            dependencies: [
                "Allocate",
                "Design",
                "Execute",
                "Store",
                "UISupport",
                "Validate",
                "Worktree",
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ]
        ),
        .testTarget(
            name: "WorkflowContainerTests",
            dependencies: [
                "WorkflowContainer",
                "Worktree",
                "Agent",
                "Allocate",
                "Chat",
                "Design",
                "Execute",
                "Store",
                "Validate",
                .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
