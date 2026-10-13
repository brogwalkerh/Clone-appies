// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Core",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CleanerCore", targets: ["CleanerCore"]),
        .library(name: "CleanerCoreTesting", targets: ["CleanerCoreTesting"]),
    ],
    targets: [
        .target(
            name: "CleanerCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "CleanerCoreTesting",
            dependencies: ["CleanerCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CleanerCoreTests",
            dependencies: ["CleanerCore", "CleanerCoreTesting"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ],
    swiftLanguageModes: [.v6]
)
