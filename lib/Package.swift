// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "HerculesApp",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HerculesApp", targets: ["HerculesApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-clocks", exact: "1.0.6"),
        .package(url: "https://github.com/pointfreeco/swift-dependencies", exact: "1.12.0"),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", exact: "1.19.2"),
        .package(url: "https://github.com/pointfreeco/swift-custom-dump", exact: "1.5.0"),
        .package(url: "https://github.com/swiftlang/swift-subprocess", exact: "0.4.0"),
    ],
    targets: [
        .target(
            name: "Agent",
            dependencies: [
                "Transcript",
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesMacros", package: "swift-dependencies"),
                .product(name: "Subprocess", package: "swift-subprocess"),
            ]
        ),
        .testTarget(
            name: "AgentTests",
            dependencies: [
                "Agent",
                "Transcript",
                .product(name: "Clocks", package: "swift-clocks"),
                .product(name: "CustomDump", package: "swift-custom-dump"),
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
                .product(name: "SnapshotTestingCustomDump", package: "swift-snapshot-testing"),
                .product(name: "Subprocess", package: "swift-subprocess"),
            ],
            resources: [
                .copy("Fixtures"),
            ]
        ),
        .target(
            name: "HerculesApp",
            dependencies: [
                "Agent",
                "TestChat",
            ]
        ),
        .testTarget(
            name: "HerculesAppTests",
            dependencies: [
                "HerculesApp",
            ]
        ),
        .target(
            name: "TestChat",
            dependencies: [
                "Agent",
                "Transcript",
                .product(name: "Dependencies", package: "swift-dependencies"),
            ]
        ),
        .target(
            name: "Transcript"
        ),
        .testTarget(
            name: "TranscriptTests",
            dependencies: [
                "Transcript",
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
