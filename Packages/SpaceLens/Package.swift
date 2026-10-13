// swift-tools-version: 6.0
import PackageDescription

// Swift 6 language mode (the default for tools-version 6.0) enables complete
// strict concurrency checking, which is what CONTRACTS.md requires.
let package = Package(
    name: "SpaceLens",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SpaceLens", targets: ["SpaceLens"]),
    ],
    dependencies: [
        .package(path: "../Core"),
    ],
    targets: [
        .target(
            name: "SpaceLens",
            dependencies: [
                .product(name: "CleanerCore", package: "Core"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SpaceLensTests",
            dependencies: [
                "SpaceLens",
                .product(name: "CleanerCoreTesting", package: "Core"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
