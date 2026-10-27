import XCTest
import ApplicationsModule
@testable import UIKitBridge

final class UIKitBridgeTests: XCTestCase {
    /// Smoke test that the ApplicationsModule contract we build update sources on resolves.
    func testVersionComparatorOrdersDottedVersions() {
        XCTAssertEqual(VersionComparator.compare("1.2.3", "1.10.0"), .orderedAscending)
        XCTAssertEqual(VersionComparator.compare("2.0", "2.0"), .orderedSame)
        XCTAssertEqual(VersionComparator.compare("3.1", "2.9.9"), .orderedDescending)
    }

    func testHomebrewNormalizationStripsSeparators() {
        XCTAssertEqual(HomebrewUpdateSource.normalize("Visual Studio Code"), "visualstudiocode")
        XCTAssertEqual(HomebrewUpdateSource.normalize("visual-studio-code"), "visualstudiocode")
        XCTAssertEqual(HomebrewUpdateSource.normalize("iTerm2"), "iterm2")
    }

    func testHomebrewMatchesCaskTokenToApp() {
        let app = InstalledApp(bundleURL: URL(fileURLWithPath: "/Applications/Visual Studio Code.app"),
                               name: "Visual Studio Code",
                               bundleIdentifier: "com.microsoft.VSCode",
                               version: "1.90.0",
                               build: nil,
                               source: .homebrewCask,
                               sizeBytes: 0,
                               lastOpened: nil,
                               sparkleFeedURL: nil)
        let cask = HomebrewUpdateSource.OutdatedCask(name: "visual-studio-code",
                                                     installedVersions: ["1.90.0"],
                                                     currentVersion: "1.91.0")
        let updates = HomebrewUpdateSource.match(casks: [cask], to: [app])
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates.first?.latestVersion, "1.91.0")
        XCTAssertEqual(updates.first?.source, .homebrewCask)
    }

    func testChunkingSplitsIntoBatches() {
        XCTAssertEqual(Array(1...45).chunked(into: 20).map(\.count), [20, 20, 5])
        XCTAssertEqual([Int]().chunked(into: 20).count, 0)
    }
}
