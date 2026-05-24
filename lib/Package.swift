// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "HerculesApp",
    platforms: [.iOS(.v18), .macOS(.v15), .visionOS(.v2)],
    products: [
        .library(name: "HerculesApp", targets: ["HerculesApp"]),
    ],
    dependencies: [
    ],
    targets: [
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
