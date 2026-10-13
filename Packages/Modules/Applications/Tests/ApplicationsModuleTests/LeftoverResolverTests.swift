import Foundation
import Testing
import CleanerCore
import CleanerCoreTesting
@testable import ApplicationsModule

@Suite("LeftoverResolver")
struct LeftoverResolverTests {
    let app = makeApp(name: "Fancy", id: "com.vendor.fancy", path: "/Applications/Fancy Pro.app")

    var fs: MockFileSystem {
        [
            "/Users/test/Library/Application Support/com.vendor.fancy/db.sqlite": .file(size: 1_000),
            "/Users/test/Library/Application Support/com.vendor.fancy/blobs/a": .file(size: 500),
            "/Users/test/Library/Application Support/Fancy/settings.json": .file(size: 10),
            "/Users/test/Library/Application Support/Fancy Pro/x": .file(size: 20),
            "/Users/test/Library/Application Support/com.other.app/x": .file(size: 99),
            "/Users/test/Library/Caches/com.vendor.fancy/c.bin": .file(size: 2_000),
            "/Users/test/Library/Preferences/com.vendor.fancy.plist": .file(size: 300, modified: daysAgo(3)),
            "/Users/test/Library/Preferences/com.other.app.plist": .file(size: 300),
            "/Users/test/Library/Containers/com.vendor.fancy/Data/Library/x": .file(size: 4_000),
            "/Users/test/Library/Group Containers/ABC123.com.vendor.fancy/shared.db": .file(size: 50),
            "/Users/test/Library/Group Containers/group.vendor.fancy.shared/y": .file(size: 60),
            "/Users/test/Library/Group Containers/XYZ.com.other.app/z": .file(size: 70),
            "/Users/test/Library/Saved Application State/com.vendor.fancy.savedState/data.data": .file(size: 80),
            "/Users/test/Library/LaunchAgents/com.vendor.fancy.helper.plist": .file(size: 90),
            "/Users/test/Library/LaunchAgents/com.vendor.fancy.plist": .file(size: 91),
            "/Users/test/Library/LaunchAgents/com.other.app.plist": .file(size: 92),
            "/Users/test/Library/LaunchAgents/com.vendor.fancy.notes.txt": .file(size: 93),
            "/Users/test/Library/Logs/com.vendor.fancy/log.txt": .file(size: 100),
            "/Users/test/Library/Logs/Fancy/log.txt": .file(size: 110),
            "/Users/test/Library/HTTPStorages/com.vendor.fancy/httpstorages.sqlite": .file(size: 120),
            "/Users/test/Library/HTTPStorages/com.vendor.fancy.binarycookies": .file(size: 121),
            "/Users/test/Library/WebKit/com.vendor.fancy/WebsiteData/x": .file(size: 130),
            "/Users/test/Library/Application Scripts/com.vendor.fancy/script.sh": .file(size: 140),
            "/Users/test/Library/Cookies/com.vendor.fancy.binarycookies": .file(size: 150),
        ]
    }

    @Test func findsEveryLocationType() async throws {
        let findings = await LeftoverResolver(fileSystem: fs, protectedPaths: .none).leftovers(for: app, home: testHome)
        let home = "/Users/test/Library/"
        let expected: Set<String> = [
            "Application Support/com.vendor.fancy",
            "Application Support/Fancy",
            "Application Support/Fancy Pro",
            "Caches/com.vendor.fancy",
            "Preferences/com.vendor.fancy.plist",
            "Containers/com.vendor.fancy",
            "Group Containers/ABC123.com.vendor.fancy",
            "Group Containers/group.vendor.fancy.shared",
            "Saved Application State/com.vendor.fancy.savedState",
            "LaunchAgents/com.vendor.fancy.helper.plist",
            "LaunchAgents/com.vendor.fancy.plist",
            "Logs/com.vendor.fancy",
            "Logs/Fancy",
            "HTTPStorages/com.vendor.fancy",
            "HTTPStorages/com.vendor.fancy.binarycookies",
            "WebKit/com.vendor.fancy",
            "Application Scripts/com.vendor.fancy",
            "Cookies/com.vendor.fancy.binarycookies",
        ].map { home + $0 }.reduce(into: Set<String>()) { $0.insert($1) }
        #expect(findings.paths == expected, "missing: \(expected.subtracting(findings.paths)) extra: \(findings.paths.subtracting(expected))")
        #expect(findings.count == expected.count, "no duplicates")
        #expect(findings.allSatisfy { $0.category.id == "applications.leftovers" })
        #expect(findings.allSatisfy { $0.category.module == .applications })
        #expect(findings.allSatisfy { $0.risk == .safe })
        #expect(findings.allSatisfy { $0.detail == "Fancy support file" })
        #expect(findings.allSatisfy { $0.scannerID == "applications.leftovers" })

        let support = try #require(findings.at("/Users/test/Library/Application Support/com.vendor.fancy"))
        #expect(support.isDirectory)
        #expect(support.sizeBytes == 1_500)
        let prefs = try #require(findings.named("com.vendor.fancy.plist"))
        #expect(!prefs.isDirectory)
        #expect(prefs.sizeBytes == 300)
        #expect(prefs.modifiedAt == daysAgo(3))
        #expect(findings.named("com.vendor.fancy.savedState")?.sizeBytes == 80)
    }

    @Test func nothingWithoutBundleIdentifier() async {
        let anonymous = makeApp(name: "Fancy", id: nil)
        let findings = await LeftoverResolver(fileSystem: fs, protectedPaths: .none).leftovers(for: anonymous, home: testHome)
        #expect(findings.isEmpty)
        let empty = makeApp(name: "Fancy", id: "")
        #expect(await LeftoverResolver(fileSystem: fs, protectedPaths: .none).leftovers(for: empty, home: testHome).isEmpty)
    }

    @Test func nothingForUnknownApp() async {
        let stranger = makeApp(name: "Stranger", id: "org.nobody.stranger")
        let findings = await LeftoverResolver(fileSystem: fs, protectedPaths: .none).leftovers(for: stranger, home: testHome)
        #expect(findings.isEmpty)
    }

    @Test func protectedPathsAreExcluded() async {
        let protected = ProtectedPaths(prefixes: [
            URL(fileURLWithPath: "/Users/test/Library/Containers/com.vendor.fancy"),
            URL(fileURLWithPath: "/Users/test/Library/Group Containers"),
        ])
        let findings = await LeftoverResolver(fileSystem: fs, protectedPaths: protected).leftovers(for: app, home: testHome)
        #expect(!findings.paths.contains("/Users/test/Library/Containers/com.vendor.fancy"))
        #expect(!findings.paths.contains { $0.contains("Group Containers") })
        #expect(findings.paths.contains("/Users/test/Library/Caches/com.vendor.fancy"))
    }

    @Test func defaultInitUsesDefaultProtectedPaths() async {
        let findings = await LeftoverResolver(fileSystem: fs).leftovers(for: app, home: testHome)
        #expect(findings.paths.contains("/Users/test/Library/Caches/com.vendor.fancy"))
    }

    @Test func groupContainerMatchingIsComponentAware() {
        #expect(BundleIdentifier.name("ABC123.com.vendor.fancy", containsComponents: "com.vendor.fancy"))
        #expect(BundleIdentifier.name("group.vendor.fancy.shared", containsComponents: "vendor.fancy"))
        #expect(!BundleIdentifier.name("group.vendor.fancyx", containsComponents: "vendor.fancy"))
        #expect(!BundleIdentifier.name("group.avendor.fancy", containsComponents: "vendor.fancy"))
        #expect(BundleIdentifier.vendorSuffix("com.vendor.fancy") == "vendor.fancy")
        #expect(BundleIdentifier.vendorSuffix("fancy") == nil)
    }
}
