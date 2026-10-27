import Foundation
import Testing
import CleanerCore
import CleanerCoreTesting
@testable import ApplicationsModule

@Suite("OrphanedLeftoversScanner")
struct OrphanedLeftoversScannerTests {
    let scanner = OrphanedLeftoversScanner()

    var fs: MockFileSystem {
        [
            "/Applications/Keeper.app/Contents/Info.plist": infoPlist(name: "Keeper", id: "com.vendor.keeper"),
            "/Applications/Safari.app/Contents/Info.plist": infoPlist(name: "Safari", id: "com.apple.Safari"),
            // Application Support
            "/Users/test/Library/Application Support/com.vendor.keeper/db": .file(size: 1),
            "/Users/test/Library/Application Support/com.vendor.keeper.helper/x": .file(size: 2),
            "/Users/test/Library/Application Support/com.vendor/x": .file(size: 3),
            "/Users/test/Library/Application Support/com.gone.app/data.db": .file(size: 1_000),
            "/Users/test/Library/Application Support/com.gone.app/sub/blob": .file(size: 2_000),
            "/Users/test/Library/Application Support/Firefox/profiles.ini": .file(size: 4),
            "/Users/test/Library/Application Support/com.google.Keystone/x": .file(size: 5),
            "/Users/test/Library/Application Support/com.adobe.Reader/x": .file(size: 6),
            "/Users/test/Library/Application Support/CrashReporter/x": .file(size: 7),
            "/Users/test/Library/Application Support/two.parts/x": .file(size: 8),
            // Caches
            "/Users/test/Library/Caches/com.apple.Safari/x": .file(size: 9),
            "/Users/test/Library/Caches/com.apple.nothing.installed/x": .file(size: 10),
            "/Users/test/Library/Caches/org.gone.tool/x": .file(size: 11),
            "/Users/test/Library/Caches/pip/x": .file(size: 12),
            // Preferences
            "/Users/test/Library/Preferences/com.gone.app.plist": .file(size: 13),
            "/Users/test/Library/Preferences/com.vendor.keeper.plist": .file(size: 14),
            "/Users/test/Library/Preferences/com.apple.finder.plist": .file(size: 15),
            "/Users/test/Library/Preferences/.GlobalPreferences.plist": .file(size: 16),
            "/Users/test/Library/Preferences/com.gone.app.plist.lockfile": .file(size: 17),
            "/Users/test/Library/Preferences/ByHost/com.gone.app.ABC.plist": .file(size: 18),
            "/Users/test/Library/Preferences/com.gone.other": .directory,
            // Containers
            "/Users/test/Library/Containers/com.gone.app/Data/x": .file(size: 19),
            "/Users/test/Library/Containers/com.vendor.keeper/Data/x": .file(size: 20),
            // Saved Application State
            "/Users/test/Library/Saved Application State/com.gone.app.savedState/d": .file(size: 21),
            "/Users/test/Library/Saved Application State/com.vendor.keeper.savedState/d": .file(size: 22),
            // HTTPStorages
            "/Users/test/Library/HTTPStorages/com.gone.app.binarycookies": .file(size: 23),
            "/Users/test/Library/HTTPStorages/com.gone.app/x": .file(size: 24),
            // WebKit
            "/Users/test/Library/WebKit/com.gone.app/WebsiteData/x": .file(size: 25),
            "/Users/test/Library/WebKit/com.vendor.keeper/x": .file(size: 26),
            // LaunchAgents
            "/Users/test/Library/LaunchAgents/com.gone.app.agent.plist": .file(size: 27),
            "/Users/test/Library/LaunchAgents/com.vendor.keeper.agent.plist": .file(size: 28),
            "/Users/test/Library/LaunchAgents/com.google.keystone.agent.plist": .file(size: 29),
            "/Users/test/Library/LaunchAgents/com.gone.app.sh": .file(size: 30),
            // Not scanned.
            "/Users/test/Library/Logs/com.gone.app/x": .file(size: 31),
            "/Users/test/Library/Group Containers/group.com.gone.app/x": .file(size: 32),
        ]
    }

    @Test func reportsOnlyUnknownBundleIdentifiers() async throws {
        let findings = try await collect(scanner, context(fs))
        let lib = "/Users/test/Library/"
        let expected: Set<String> = Set([
            "Application Support/com.gone.app",
            "Caches/org.gone.tool",
            "Preferences/com.gone.app.plist",
            "Containers/com.gone.app",
            "Saved Application State/com.gone.app.savedState",
            "HTTPStorages/com.gone.app.binarycookies",
            "HTTPStorages/com.gone.app",
            "WebKit/com.gone.app",
            "LaunchAgents/com.gone.app.agent.plist",
        ].map { lib + $0 })
        #expect(findings.paths == expected, "missing: \(expected.subtracting(findings.paths)) extra: \(findings.paths.subtracting(expected))")
        #expect(findings.allSatisfy { $0.category.id == "applications.orphaned" })
        #expect(findings.allSatisfy { $0.category.module == .applications })
        #expect(findings.allSatisfy { $0.scannerID == "applications.orphanedLeftovers" })
        #expect(findings.allSatisfy { $0.risk == .safe })
        #expect(findings.allSatisfy { $0.detail == "Left behind by an app that is no longer installed" })
        let support = try #require(findings.at(lib + "Application Support/com.gone.app"))
        #expect(support.isDirectory)
        #expect(support.sizeBytes == 3_000)
        #expect(findings.named("com.gone.app.binarycookies")?.isDirectory == false)
        #expect(findings.named("com.gone.app.binarycookies")?.sizeBytes == 23)
    }

    @Test func knownAndAppleIdentifiersAreExcluded() async throws {
        let findings = try await collect(scanner, context(fs))
        #expect(!findings.paths.contains { $0.contains("com.vendor.keeper") })
        #expect(!findings.paths.contains { $0.contains("com.vendor/") })
        #expect(!findings.paths.contains { $0.contains("com.apple") })
        #expect(!findings.paths.contains { $0.contains("com.google") })
        #expect(!findings.paths.contains { $0.contains("com.adobe") })
    }

    @Test func namesThatAreNotBundleIdentifiersAreSkipped() async throws {
        let findings = try await collect(scanner, context(fs))
        for name in ["Firefox", "CrashReporter", "two.parts", "pip", ".GlobalPreferences.plist",
                     "com.gone.app.plist.lockfile", "ByHost", "com.gone.other", "com.gone.app.sh"] {
            #expect(findings.named(name) == nil, "\(name)")
        }
    }

    @Test func installingTheAppRemovesTheOrphan() async throws {
        var tree = fs
        tree = MockFileSystem([
            "/Applications/Gone.app/Contents/Info.plist": infoPlist(name: "Gone", id: "com.gone.app"),
            "/Users/test/Library/Application Support/com.gone.app/data.db": .file(size: 1),
            "/Users/test/Library/Caches/org.gone.tool/x": .file(size: 11),
        ])
        let findings = try await collect(scanner, context(tree))
        #expect(findings.paths == ["/Users/test/Library/Caches/org.gone.tool"])
    }

    @Test func ignoreListAndProtectedPathsAreRespected() async throws {
        let ignore = IgnoreList(paths: [URL(fileURLWithPath: "/Users/test/Library/Caches/org.gone.tool")])
        let protected = ProtectedPaths(prefixes: [URL(fileURLWithPath: "/Users/test/Library/Containers")])
        let findings = try await collect(scanner, context(fs, ignore: ignore, protected: protected))
        #expect(findings.named("org.gone.tool") == nil)
        #expect(!findings.paths.contains { $0.contains("/Containers/") })
        #expect(findings.at("/Users/test/Library/Application Support/com.gone.app") != nil)
    }

    @Test func emptyLibraryYieldsNothing() async throws {
        let findings = try await collect(scanner, context(["/Users/test/Documents/a": .file(size: 1)]))
        #expect(findings.isEmpty)
    }

    @Test func bundleIdentifierExtraction() {
        #expect(BundleIdentifier.extract(from: "com.vendor.app") == "com.vendor.app")
        #expect(BundleIdentifier.extract(from: "Com.Vendor.App") == "Com.Vendor.App")
        #expect(BundleIdentifier.extract(from: "com.vendor.app Crash Logs") == "com.vendor.app")
        #expect(BundleIdentifier.extract(from: "com.vendor.app-helper_2") == "com.vendor.app-helper")
        #expect(BundleIdentifier.extract(from: "com.vendor") == nil)
        #expect(BundleIdentifier.extract(from: "com.vendor..app") == nil)
        #expect(BundleIdentifier.extract(from: "Firefox") == nil)
        #expect(BundleIdentifier.extract(from: ".GlobalPreferences") == nil)
        #expect(BundleIdentifier.extract(fromFileName: "com.vendor.app.plist") == "com.vendor.app")
        #expect(BundleIdentifier.extract(fromFileName: "com.vendor.app.savedState") == "com.vendor.app")
        #expect(BundleIdentifier.extract(fromFileName: "com.vendor.app.binarycookies") == "com.vendor.app")
        #expect(BundleIdentifier.extract(fromFileName: "com.vendor.app.plist.lockfile") == "com.vendor.app.plist.lockfile", "only known leftover extensions are stripped")
    }

    @Test func knownIdentifierMatching() {
        let known = KnownIdentifiers(apps: [makeApp(name: "K", id: "com.vendor.app")])
        #expect(known.contains("com.vendor.app"))
        #expect(known.contains("COM.Vendor.App"))
        #expect(known.contains("com.vendor.app.helper"))
        #expect(known.contains("com.vendor"))
        #expect(known.contains("group.com.vendor.app"))
        #expect(known.contains("com.apple.anything.at.all"))
        #expect(known.contains("com.adobe.Reader"))
        #expect(known.contains("com.google.Keystone"))
        #expect(!known.contains("com.google.Chrome"))
        #expect(!known.contains("com.vendorx.app"))
        #expect(!known.contains("com.other.app"))
    }
}
