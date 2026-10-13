// swift-tools-version: 6.0
import PackageDescription

// Swift 6 language mode (the default for tools-version 6.0) enables complete
// strict concurrency checking, which is what CONTRACTS.md requires.
let package = Package(
    name: "Performance",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PerformanceModule", targets: ["PerformanceModule"]),
    ],
    dependencies: [
        .package(path: "../../Core"),
        .package(path: "../../HelperProtocol"),
    ],
    targets: [
        .target(
            name: "PerformanceModule",
            dependencies: [
                .product(name: "CleanerCore", package: "Core"),
                .product(name: "HelperProtocol", package: "HelperProtocol"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PerformanceModuleTests",
            dependencies: [
                "PerformanceModule",
                .product(name: "CleanerCoreTesting", package: "Core"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ],
    swiftLanguageModes: [.v6]
)
