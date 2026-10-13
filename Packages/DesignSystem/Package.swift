// swift-tools-version: 6.0
import PackageDescription

// DesignSystem: colors, Liquid Glass components, shared views.
// macOS only (imports SwiftUI). Depends on nothing else in the workspace.
let package = Package(
    name: "DesignSystem",
    platforms: [
        // Deployment target per PLAN.md §2. String form so the manifest parses even
        // if this toolchain's `SupportedPlatform.MacOSVersion` lacks a `.v27` case.
        .macOS("27.0")
    ],
    products: [
        .library(name: "DesignSystem", targets: ["DesignSystem"])
    ],
    targets: [
        .target(
            name: "DesignSystem",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "DesignSystemTests",
            dependencies: ["DesignSystem"]
        )
    ]
)
