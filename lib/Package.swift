// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "HerculesApp",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HerculesApp", targets: ["HerculesApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/sqlite-data", from: "1.0.0"),
        .package(url: "https://github.com/pointfreeco/swift-clocks", exact: "1.0.6"),
        .package(url: "https://github.com/pointfreeco/swift-custom-dump", exact: "1.5.0"),
        .package(url: "https://github.com/pointfreeco/swift-dependencies", exact: "1.12.0"),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", exact: "1.19.2"),
        .package(url: "https://github.com/pointfreeco/swift-structured-queries", exact: "0.31.1"),
        .package(url: "https://github.com/swiftlang/swift-subprocess", exact: "0.5.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", from: "0.11.0"),
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
                "Material",
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
                "Material",
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
                "Material",
                "Store",
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ]
        ),
        .testTarget(
            name: "DesignTests",
            dependencies: [
                "Design",
                "Material",
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
                "Design",
                "IssueMCP",
                "TestChat",
                "WorkflowContainer",
            ]
        ),
        .testTarget(
            name: "HerculesAppTests",
            dependencies: [
                "HerculesApp",
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
            name: "Material",
            resources: [
                .copy("Resources"),
            ]
        ),
        .testTarget(
            name: "MaterialTests",
            dependencies: [
                "Material",
            ]
        ),
        .target(
            name: "PRD",
            dependencies: [
                "Agent",
                "Chat",
                "Material",
                "Store",
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ]
        ),
        .testTarget(
            name: "PRDTests",
            dependencies: [
                "PRD",
                "Agent",
                "Material",
                "Store",
                .product(name: "CustomDump", package: "swift-custom-dump"),
                .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
                .product(name: "SQLiteData", package: "sqlite-data"),
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
            name: "WorkflowContainer",
            dependencies: [
                "Design",
                "PRD",
                "Store",
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ]
        ),
        .testTarget(
            name: "WorkflowContainerTests",
            dependencies: [
                "WorkflowContainer",
                .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
