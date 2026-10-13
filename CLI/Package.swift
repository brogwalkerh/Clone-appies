// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CLI",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "maccleaner", targets: ["maccleaner"]),
    ],
    dependencies: [
        .package(path: "../Packages/Core"),
        .package(path: "../Packages/Modules/Cleanup"),
        .package(path: "../Packages/Modules/Clutter"),
        .package(path: "../Packages/Modules/Applications"),
        .package(path: "../Packages/Modules/Performance"),
        .package(path: "../Packages/HelperProtocol"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "maccleaner",
            dependencies: [
                .product(name: "CleanerCore", package: "Core"),
                .product(name: "CleanupModule", package: "Cleanup"),
                .product(name: "ClutterModule", package: "Clutter"),
                .product(name: "ApplicationsModule", package: "Applications"),
                .product(name: "PerformanceModule", package: "Performance"),
                .product(name: "HelperProtocol", package: "HelperProtocol"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "maccleanerTests",
            dependencies: [
                "maccleaner",
                .product(name: "CleanerCore", package: "Core"),
                .product(name: "CleanerCoreTesting", package: "Core"),
                .product(name: "PerformanceModule", package: "Performance"),
                .product(name: "HelperProtocol", package: "HelperProtocol"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ],
    swiftLanguageModes: [.v6]
)
