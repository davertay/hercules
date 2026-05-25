// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "HerculesApp",
    platforms: [.iOS(.v18), .macOS(.v15), .visionOS(.v2)],
    products: [
        .library(name: "Agent", targets: ["Agent"]),
        .library(name: "HerculesApp", targets: ["HerculesApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.0.0"),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.17.0"),
        .package(url: "https://github.com/pointfreeco/swift-custom-dump", from: "1.0.0"),
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
