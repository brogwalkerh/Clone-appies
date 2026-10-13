// swift-tools-version: 6.0
import PackageDescription

// Swift 6 language mode (the default for tools-version 6.0) enables complete
// strict concurrency checking, which is what CONTRACTS.md requires.
let package = Package(
    name: "Protection",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ProtectionModule", targets: ["ProtectionModule"]),
    ],
    dependencies: [
        .package(path: "../../Core"),
    ],
    targets: [
        .target(
            name: "ProtectionModule",
            dependencies: [
                .product(name: "CleanerCore", package: "Core"),
                .product(name: "CleanerHashing", package: "Core"),
            ],
            resources: [.copy("Resources/signatures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ProtectionModuleTests",
            dependencies: [
                "ProtectionModule",
                .product(name: "CleanerCoreTesting", package: "Core"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ],
    swiftLanguageModes: [.v6]
)
