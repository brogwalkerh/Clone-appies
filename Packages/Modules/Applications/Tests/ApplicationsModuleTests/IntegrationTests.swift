import Foundation
import Testing
import CleanerCore
import CleanerCoreTesting
@testable import ApplicationsModule

@Suite("Applications integration")
struct IntegrationTests {
    @Test func allScannersHaveApplicationsModuleAndUniqueIDs() {
        let scanners = ApplicationsScanners.all()
        #expect(scanners.count == 2)
        let ids = scanners.map { type(of: $0).id }
        #expect(ids == ["applications.orphanedLeftovers", "applications.installers"])
        #expect(Set(ids).count == ids.count)
        #expect(scanners.allSatisfy { $0.module == .applications })
        #expect(scanners.allSatisfy { !$0.displayName.isEmpty })
    }

    @Test func coordinatorRunOverRealFixtureTree() async throws {
        let fixture = try FixtureBuilder(name: "applications")
        defer { try? fixture.remove() }
        let tenDaysAgo = Date().addingTimeInterval(-10 * 86_400)
        try fixture.build([
            "Applications/Installed.app/Contents/Info.plist": infoPlist(name: "Installed", id: "com.example.installed", version: "1.0", build: "1"),
            "Applications/Installed.app/Contents/MacOS/Installed": .file(size: 2_048),
            "Library/Application Support/com.example.installed/data.db": .file(size: 100),
            "Library/Application Support/com.example.installed.helper/x": .file(size: 100),
            "Library/Application Support/com.example.vanished/data.db": .file(size: 1_000),
            "Library/Application Support/com.example.vanished/blobs/b": .file(size: 2_000),
            "Library/Application Support/Plain Folder/x": .file(size: 10),
            "Library/Caches/com.apple.Safari/x": .file(size: 10),
            "Library/Caches/org.example.vanishedtool/x": .file(size: 300),
            "Library/Preferences/com.example.vanished.plist": .file(size: 400),
            "Library/Preferences/com.example.installed.plist": .file(size: 10),
            "Library/Saved Application State/com.example.vanished.savedState/d": .file(size: 500),
            "Library/LaunchAgents/com.example.vanished.agent.plist": .file(size: 600),
            "Library/Containers/com.example.vanished/Data/x": .file(size: 700),
            "Downloads/Installer.dmg": .file(size: 8_000, modified: tenDaysAgo),
            "Downloads/notes.txt": .file(size: 1),
            "Desktop/Tool.pkg": .file(size: 9_000, modified: tenDaysAgo),
            "Documents/Thesis/thesis.pdf": .file(size: 12_000),
        ])

        let context = ScanContext(fileSystem: LocalFileSystem(), home: fixture.root)
        let coordinator = ScanCoordinator(scanners: ApplicationsScanners.all())
        var findings: [Finding] = []
        var summary: ScanSummary?
        var failures: [String] = []
        for await event in await coordinator.run(context) {
            switch event {
            case .finding(let f): findings.append(f)
            case .completed(let s): summary = s
            case .failed(let id, let message): failures.append("\(id): \(message)")
            default: break
            }
        }

        #expect(failures.isEmpty, "scanner failures: \(failures)")
        let summaryValue = try #require(summary)
        #expect(summaryValue.totalFindings == findings.count)
        #expect(summaryValue.totalBytes == findings.totalBytes)

        let home = fixture.root.path
        let relative = Set(findings.map { String($0.path.standardizedFileURL.path.dropFirst(home.count + 1)) })
        let expected: Set<String> = [
            "Library/Application Support/com.example.vanished",
            "Library/Caches/org.example.vanishedtool",
            "Library/Preferences/com.example.vanished.plist",
            "Library/Saved Application State/com.example.vanished.savedState",
            "Library/LaunchAgents/com.example.vanished.agent.plist",
            "Library/Containers/com.example.vanished",
            "Downloads/Installer.dmg",
            "Desktop/Tool.pkg",
        ]
        #expect(relative == expected, "missing: \(expected.subtracting(relative)) unexpected: \(relative.subtracting(expected))")

        let byPath = Dictionary(findings.map { (String($0.path.standardizedFileURL.path.dropFirst(home.count + 1)), $0) },
                                uniquingKeysWith: { a, _ in a })
        #expect(byPath["Library/Application Support/com.example.vanished"]?.sizeBytes == 3_000)
        #expect(byPath["Library/Application Support/com.example.vanished"]?.category.id == "applications.orphaned")
        #expect(byPath["Downloads/Installer.dmg"]?.category.id == "applications.installers")
        #expect(byPath["Downloads/Installer.dmg"]?.detail == "Installer, 10 days old")
        #expect(byPath["Desktop/Tool.pkg"]?.risk == .caution)
        #expect(summaryValue.byCategory["applications.installers"] == 17_000)
        #expect(summaryValue.byCategory["applications.orphaned"] == 5_500)
    }

    @Test func inventoryAndLeftoversOverRealFixtureTree() async throws {
        let fixture = try FixtureBuilder(name: "applications-inventory")
        defer { try? fixture.remove() }
        try fixture.build([
            "Applications/Real.app/Contents/Info.plist": infoPlist(name: "Real", id: "com.example.real", version: "2.0", build: "200", feed: "https://example.com/real.xml"),
            "Applications/Real.app/Contents/MacOS/Real": .file(size: 4_096),
            "Applications/Real.app/Contents/Resources/r.dat": .file(size: 1_000),
            "Applications/Store.app/Contents/Info.plist": infoPlist(name: "Store", id: "com.example.store"),
            "Applications/Store.app/Contents/_MASReceipt/receipt": .file(size: 10),
            "Caskroom/real/2.0/Linked.app/Contents/Info.plist": infoPlist(name: "Linked", id: "com.example.linked"),
            "Caskroom/real/2.0/Linked.app/Contents/MacOS/Linked": .file(size: 1),
            "Library/Application Support/com.example.real/x": .file(size: 50),
            "Library/Application Support/Real/y": .file(size: 60),
            "Library/Preferences/com.example.real.plist": .file(size: 70),
            "Library/Group Containers/TEAM.com.example.real/z": .file(size: 80),
            "Library/LaunchAgents/com.example.real.agent.plist": .file(size: 90),
        ])
        try fixture.symlink("Applications/Linked.app", to: "Caskroom/real/2.0/Linked.app")

        let inventory = AppInventory(fileSystem: LocalFileSystem(), searchPaths: [], caskrooms: [fixture.url("Caskroom").path])
        let apps = try await inventory.discover(home: fixture.root)
        #expect(apps.names == ["Linked", "Real", "Store"])
        let real = try #require(apps.named("Real"))
        #expect(real.source == .direct)
        #expect(real.sizeBytes == 5_096 + Int64(infoPlistData(name: "Real", id: "com.example.real", version: "2.0", build: "200", feed: "https://example.com/real.xml").count))
        #expect(real.version == "2.0")
        #expect(real.build == "200")
        #expect(real.sparkleFeedURL == URL(string: "https://example.com/real.xml"))
        #expect(apps.named("Store")?.source == .appStore)
        let linked = try #require(apps.named("Linked"))
        #expect(linked.source == .homebrewCask)
        #expect(linked.bundleURL == fixture.url("Applications/Linked.app").standardizedFileURL)
        #expect(apps.filter { $0.bundleIdentifier == "com.example.linked" }.count == 1)

        let leftovers = await LeftoverResolver(fileSystem: LocalFileSystem()).leftovers(for: real, home: fixture.root)
        let relative = Set(leftovers.map { String($0.path.standardizedFileURL.path.dropFirst(fixture.root.path.count + 1)) })
        #expect(relative == [
            "Library/Application Support/com.example.real",
            "Library/Application Support/Real",
            "Library/Preferences/com.example.real.plist",
            "Library/Group Containers/TEAM.com.example.real",
            "Library/LaunchAgents/com.example.real.agent.plist",
        ])
        #expect(leftovers.totalBytes == 350)
        #expect(leftovers.allSatisfy { $0.detail == "Real support file" })
    }
}
