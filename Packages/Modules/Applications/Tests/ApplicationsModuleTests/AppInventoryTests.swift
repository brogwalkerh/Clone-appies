import Foundation
import Testing
import CleanerCore
import CleanerCoreTesting
@testable import ApplicationsModule

@Suite("AppInventory")
struct AppInventoryTests {
    var fs: MockFileSystem {
        [
            // Directly distributed.
            "/Applications/Direct.app/Contents/Info.plist": infoPlist(name: "Direct", id: "com.vendor.direct", version: "1.2", build: "12", feed: "https://example.com/direct.xml"),
            "/Applications/Direct.app/Contents/MacOS/Direct": .file(size: 10_000),
            "/Applications/Direct.app/Contents/Resources/big.bin": .file(size: 5_000),
            "/Applications/Direct.app/Contents/Frameworks/Nested.app/Contents/Info.plist": infoPlist(name: "Nested", id: "com.vendor.nested"),
            // App Store, Apple-made (receipt wins over com.apple. prefix).
            "/Applications/Numbers.app/Contents/Info.plist": infoPlist(name: "Numbers", id: "com.apple.iWork.Numbers", version: "14.0", build: "7040"),
            "/Applications/Numbers.app/Contents/_MASReceipt/receipt": .file(size: 300),
            // App Store, third party.
            "/Applications/Store.app/Contents/Info.plist": infoPlist(name: "Store", id: "com.vendor.store"),
            "/Applications/Store.app/Contents/_MASReceipt/receipt": .file(size: 300),
            // Apple app under /Applications.
            "/Applications/Safari.app/Contents/Info.plist": infoPlist(name: "Safari", id: "com.apple.Safari", version: "27.0", build: "27000"),
            "/Applications/Safari.app/Contents/MacOS/Safari": .file(size: 100),
            // System app.
            "/System/Applications/Mail.app/Contents/Info.plist": infoPlist(name: "Mail", id: "com.apple.mail"),
            "/System/Applications/Utilities/Terminal.app/Contents/Info.plist": infoPlist(name: "Terminal", id: "com.apple.Terminal"),
            // Utilities.
            "/Applications/Utilities/Util.app/Contents/Info.plist": infoPlist(name: "Util", id: "com.vendor.util"),
            // Setapp.
            "/Applications/Setapp/Setty.app/Contents/Info.plist": infoPlist(name: "Setty", id: "com.vendor.setty"),
            // Homebrew cask: /Applications symlink into the Caskroom.
            "/Applications/Cask.app": .symlink(to: "/opt/homebrew/Caskroom/cask/1.0/Cask.app"),
            "/opt/homebrew/Caskroom/cask/1.0/Cask.app/Contents/Info.plist": infoPlist(name: "Cask", id: "com.vendor.cask", version: "1.0", build: "1"),
            "/opt/homebrew/Caskroom/cask/1.0/Cask.app/Contents/MacOS/Cask": .file(size: 2_000),
            // Homebrew cask living only in the Caskroom (newer brew layout is the reverse).
            "/usr/local/Caskroom/other/2.0/Other.app/Contents/Info.plist": infoPlist(name: "Other", id: "com.vendor.other"),
            "/usr/local/Caskroom/other/2.0/Other.app/Contents/MacOS/Other": .file(size: 700),
            "/usr/local/Caskroom/other/.metadata/2.0/x": .file(size: 1),
            // New brew layout: real app in /Applications, Caskroom holds a symlink back.
            "/Applications/Modern.app/Contents/Info.plist": infoPlist(name: "Modern", id: "com.vendor.modern"),
            "/opt/homebrew/Caskroom/modern/3.0/Modern.app": .symlink(to: "/Applications/Modern.app"),
            // User applications.
            "/Users/test/Applications/Mine.app/Contents/Info.plist": infoPlist(displayName: "Mine Display", executable: "Mine", id: "com.vendor.mine"),
            // Bundle without a plist, and non-app noise.
            "/Applications/NoPlist.app/Contents/MacOS/NoPlist": .file(size: 50),
            "/Applications/readme.txt": .file(size: 5),
            "/Applications/Dangling.app": .symlink(to: "/nowhere/Dangling.app"),
        ]
    }

    @Test func discoversAcrossRootsWithSourceHeuristics() async throws {
        let apps = try await AppInventory(fileSystem: fs).discover(home: testHome)
        let bySource = Dictionary(uniqueKeysWithValues: apps.map { ($0.name, $0.source) })
        #expect(bySource["Direct"] == .direct)
        #expect(bySource["Numbers"] == .appStore)
        #expect(bySource["Store"] == .appStore)
        #expect(bySource["Safari"] == .system)
        #expect(bySource["Mail"] == .system)
        #expect(bySource["Terminal"] == .system)
        #expect(bySource["Util"] == .direct)
        #expect(bySource["Setty"] == .setapp)
        #expect(bySource["Cask"] == .homebrewCask)
        #expect(bySource["Other"] == .homebrewCask)
        #expect(bySource["Modern"] == .homebrewCask)
        #expect(bySource["Mine Display"] == .direct)
        #expect(bySource["NoPlist"] == .unknown)
        #expect(apps.named("Nested") == nil, "bundles are not entered looking for more apps")
        #expect(apps.named("Dangling") == nil)
        #expect(apps.named("readme") == nil)
        #expect(apps.count == 13)
    }

    @Test func readsPlistFieldsAndSizes() async throws {
        let apps = try await AppInventory(fileSystem: fs).discover(home: testHome)
        let direct = try #require(apps.named("Direct"))
        #expect(direct.bundleIdentifier == "com.vendor.direct")
        #expect(direct.version == "1.2")
        #expect(direct.build == "12")
        #expect(direct.sparkleFeedURL == URL(string: "https://example.com/direct.xml"))
        #expect(direct.sizeBytes == 15_000 + Int64(infoPlistData(name: "Direct", id: "com.vendor.direct", version: "1.2", build: "12", feed: "https://example.com/direct.xml").count) + Int64(infoPlistData(name: "Nested", id: "com.vendor.nested").count))
        #expect(direct.lastOpened == nil)
        #expect(!direct.isSystem)
        #expect(apps.named("Safari")?.isSystem == true)
        #expect(apps.named("NoPlist")?.bundleIdentifier == nil)
        let other = try #require(apps.named("Other"))
        #expect(other.sizeBytes > 700, "Caskroom under /usr is still sized")
    }

    @Test func caskSymlinksAreResolvedAndDeduplicated() async throws {
        let apps = try await AppInventory(fileSystem: fs).discover(home: testHome)
        let cask = try #require(apps.named("Cask"))
        #expect(cask.bundleURL.path == "/Applications/Cask.app", "the /Applications path is the displayed one")
        #expect(cask.sizeBytes > 2_000)
        #expect(apps.filter { $0.bundleIdentifier == "com.vendor.cask" }.count == 1)
        let modern = try #require(apps.named("Modern"))
        #expect(modern.bundleURL.path == "/Applications/Modern.app")
        #expect(apps.filter { $0.bundleIdentifier == "com.vendor.modern" }.count == 1)
    }

    @Test func sortedByNameCaseInsensitively() async throws {
        let apps = try await AppInventory(fileSystem: fs).discover(home: testHome)
        let names = apps.names
        #expect(names == names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }

    @Test func missingRootsAreSkipped() async throws {
        let fs: MockFileSystem = ["/Users/test/Documents/x": .file(size: 1)]
        let apps = try await AppInventory(fileSystem: fs).discover(home: testHome)
        #expect(apps.isEmpty)
    }

    @Test func customRoots() async throws {
        let fs: MockFileSystem = [
            "/opt/apps/Custom.app/Contents/Info.plist": infoPlist(name: "Custom", id: "com.vendor.custom"),
            "/Applications/Ignored.app/Contents/Info.plist": infoPlist(name: "Ignored", id: "com.vendor.ignored"),
        ]
        let inventory = AppInventory(fileSystem: fs, searchPaths: ["/opt/apps"], caskrooms: [])
        let apps = try await inventory.discover(home: testHome)
        #expect(apps.names == ["Custom"])
    }

    @Test func installedAppRoundTripsThroughCodable() throws {
        let app = makeApp(name: "Round", id: "com.vendor.round", feed: "https://example.com/a.xml")
        let data = try JSONEncoder().encode(app)
        let decoded = try JSONDecoder().decode(InstalledApp.self, from: data)
        #expect(decoded == app)
        #expect(decoded.id == app.bundleURL)
        #expect(decoded.bundleStem == "Round")
    }
}
