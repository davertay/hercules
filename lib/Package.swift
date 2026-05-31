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
    ],
    targets: [
        .target(
            name: "Agent",
            dependencies: [
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesMacros", package: "swift-dependencies"),
            ]
        ),
        .testTarget(
            name: "AgentTests",
            dependencies: [
                "Agent",
                .product(name: "Clocks", package: "swift-clocks"),
                .product(name: "CustomDump", package: "swift-custom-dump"),
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
                .product(name: "SnapshotTestingCustomDump", package: "swift-snapshot-testing"),
            ],
            resources: [
                .copy("Fixtures"),
            ]
        ),
        .target(
            name: "HerculesApp",
            dependencies: [
                "Agent",
            ]
        ),
        .testTarget(
            name: "HerculesAppTests",
            dependencies: [
                "HerculesApp",
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
