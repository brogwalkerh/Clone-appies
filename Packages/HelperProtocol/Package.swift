// swift-tools-version: 6.0
import PackageDescription

// Foundation-only wire contract shared by the app, the privileged helper and
// the CLI. It depends on nothing (not even CleanerCore) so that the helper's
// validation boundary can be unit-tested on Linux (CLAUDE.md rule 1 and 5,
// ADR 0002).
let package = Package(
    name: "HelperProtocol",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HelperProtocol", targets: ["HelperProtocol"]),
    ],
    targets: [
        .target(
            name: "HelperProtocol",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "HelperProtocolTests",
            dependencies: ["HelperProtocol"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ],
    swiftLanguageModes: [.v6]
)
