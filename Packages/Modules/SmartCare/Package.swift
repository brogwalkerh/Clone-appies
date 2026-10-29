// swift-tools-version: 6.0
import PackageDescription

// Swift 6 language mode (the default for tools-version 6.0) enables complete
// strict concurrency checking, which is what CONTRACTS.md requires.
let package = Package(
    name: "SmartCare",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SmartCareModule", targets: ["SmartCareModule"]),
    ],
    dependencies: [
        .package(path: "../../Core"),
        .package(path: "../Cleanup"),
        .package(path: "../Performance"),
        .package(path: "../../HelperProtocol"),
    ],
    targets: [
        .target(
            name: "SmartCareModule",
            dependencies: [
                .product(name: "CleanerCore", package: "Core"),
                .product(name: "CleanupModule", package: "Cleanup"),
                .product(name: "PerformanceModule", package: "Performance"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SmartCareModuleTests",
            dependencies: [
                "SmartCareModule",
                .product(name: "CleanerCoreTesting", package: "Core"),
                .product(name: "HelperProtocol", package: "HelperProtocol"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ],
    swiftLanguageModes: [.v6]
)
