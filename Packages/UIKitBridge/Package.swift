// swift-tools-version: 6.0
import PackageDescription

// UIKitBridge: the macOS-only glue that CleanerCore / ClutterModule /
// ApplicationsModule / PerformanceModule deliberately leave out (Vision
// feature prints, IOKit power state and battery health, Homebrew and App Store
// update sources, NSWorkspace icons, libproc process sampling, launchctl state,
// host statistics, the Screen Cleaning event tap, Security.framework code
// signature checks, the TCC permissions database and the FSEvents-based
// Protection Monitor).
// Imports AppKit, Vision, IOKit, ImageIO, Security, SQLite3 and CoreServices,
// so it never builds on Linux
// (CLAUDE.md hard rule 1). Deployment target per ADR 0005.
let package = Package(
    name: "UIKitBridge",
    platforms: [
        // String form so the manifest parses even if this toolchain's
        // `SupportedPlatform.MacOSVersion` lacks a `.v26` case.
        .macOS("26.0")
    ],
    products: [
        .library(name: "UIKitBridge", targets: ["UIKitBridge"])
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../Modules/Clutter"),
        .package(path: "../Modules/Applications"),
        .package(path: "../Modules/Performance"),
        .package(path: "../Modules/Protection"),
    ],
    targets: [
        .target(
            name: "UIKitBridge",
            dependencies: [
                .product(name: "CleanerCore", package: "Core"),
                .product(name: "CleanerHashing", package: "Core"),
                .product(name: "ClutterModule", package: "Clutter"),
                .product(name: "ApplicationsModule", package: "Applications"),
                .product(name: "PerformanceModule", package: "Performance"),
                .product(name: "ProtectionModule", package: "Protection"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "UIKitBridgeTests",
            dependencies: [
                "UIKitBridge",
                .product(name: "CleanerCore", package: "Core"),
                .product(name: "ApplicationsModule", package: "Applications"),
                .product(name: "PerformanceModule", package: "Performance"),
                .product(name: "ProtectionModule", package: "Protection"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
