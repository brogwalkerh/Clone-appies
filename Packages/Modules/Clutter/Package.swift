// swift-tools-version: 6.0
import PackageDescription

// Swift 6 language mode (the default for tools-version 6.0) enables complete
// strict concurrency checking, which is what CONTRACTS.md requires.
let package = Package(
    name: "Clutter",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ClutterModule", targets: ["ClutterModule"]),
    ],
    dependencies: [
        .package(path: "../../Core"),
    ],
    targets: [
        .target(
            name: "ClutterModule",
            dependencies: [
                .product(name: "CleanerCore", package: "Core"),
                .product(name: "CleanerHashing", package: "Core"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ClutterModuleTests",
            dependencies: [
                "ClutterModule",
                .product(name: "CleanerCoreTesting", package: "Core"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ],
    swiftLanguageModes: [.v6]
)
