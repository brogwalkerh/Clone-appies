// swift-tools-version: 6.0
import PackageDescription

// Swift 6 language mode (the default for tools-version 6.0) enables complete
// strict concurrency checking, which is what CONTRACTS.md requires.
let package = Package(
    name: "Cleanup",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CleanupModule", targets: ["CleanupModule"]),
    ],
    dependencies: [
        .package(path: "../../Core"),
    ],
    targets: [
        .target(
            name: "CleanupModule",
            dependencies: [
                .product(name: "CleanerCore", package: "Core"),
            ],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CleanupModuleTests",
            dependencies: [
                "CleanupModule",
                .product(name: "CleanerCoreTesting", package: "Core"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ],
    swiftLanguageModes: [.v6]
)
