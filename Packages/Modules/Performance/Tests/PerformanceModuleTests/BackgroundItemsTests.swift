import Foundation
import Testing
import CleanerCore
import CleanerCoreTesting
@testable import PerformanceModule

@Suite("BackgroundItemsInventory")
struct BackgroundItemsTests {
    var fs: MockFileSystem {
        [
            // User agents
            "/Users/test/Library/LaunchAgents/com.vendor.sync.plist": launchdPlist(
                label: "com.vendor.sync", program: "/Applications/Sync.app/Contents/MacOS/syncd",
                runAtLoad: true, keepAlive: true),
            "/Applications/Sync.app/Contents/MacOS/syncd": .file(size: 10),
            "/Users/test/Library/LaunchAgents/com.gone.agent.plist": launchdPlist(
                label: "com.gone.agent", programArguments: ["~/Library/Gone/agent", "--daemon"], runAtLoad: false),
            "/Users/test/Library/LaunchAgents/com.home.ok.plist": launchdPlist(
                label: "com.home.ok", program: "~/bin/tool"),
            "/Users/test/bin/tool": .file(size: 1),
            "/Users/test/Library/LaunchAgents/broken.plist": .file("<plist><dict><key>Label</key></dict>"),
            "/Users/test/Library/LaunchAgents/notes.txt": .file("not a plist"),
            "/Users/test/Library/LaunchAgents/Folder.plist": .directory,
            "/Users/test/Library/LaunchAgents/array.plist": .file("""
                <?xml version="1.0" encoding="UTF-8"?>
                <plist version="1.0"><array><string>x</string></array></plist>
                """),
            // System agents
            "/Library/LaunchAgents/com.apple.foo.plist": launchdPlist(
                label: "com.apple.foo", programArguments: ["/usr/libexec/foo"]),
            "/usr/libexec/foo": .file(size: 1),
            "/Library/LaunchAgents/com.keep.dict.plist": launchdPlist(
                label: "com.keep.dict", program: "/opt/keep/bin/keep",
                extra: "    <key>KeepAlive</key>\n    <dict>\n        <key>SuccessfulExit</key>\n        <false/>\n    </dict>\n"),
            "/opt/keep/bin/keep": .file(size: 1),
            "/Library/LaunchAgents/com.keep.emptydict.plist": launchdPlist(
                label: "com.keep.emptydict", program: "/opt/keep/bin/keep",
                extra: "    <key>KeepAlive</key>\n    <dict/>\n"),
            // System daemons
            "/Library/LaunchDaemons/com.vendor.daemon.plist": launchdPlist(
                label: "com.vendor.daemon", program: "/Library/PrivilegedHelperTools/com.vendor.daemon",
                runAtLoad: true),
            "/Library/LaunchDaemons/noprogram.plist": launchdPlist(label: "org.noprogram"),
            "/Library/LaunchDaemons/nolabel.plist": launchdPlist(program: "/missing/x"),
            "/Library/LaunchDaemons/relative.plist": launchdPlist(label: "org.relative", programArguments: ["bash", "-c", "x"]),
            "/Library/PrivilegedHelperTools/com.vendor.daemon": .file(size: 500),
            "/Library/PrivilegedHelperTools/com.apple.helper": .file(size: 500),
            "/Library/PrivilegedHelperTools/Subdir": .directory,
        ]
    }

    func discover(_ fs: MockFileSystem, provider: (any LaunchdStateProvider)? = nil) async throws -> [BackgroundItem] {
        try await BackgroundItemsInventory(fileSystem: fs, enabledStateProvider: provider).discover(home: testHome)
    }

    @Test func discoversAllDomainsSortedByDomainThenLabel() async throws {
        let items = try await discover(fs)
        #expect(items.map { "\($0.domain.rawValue):\($0.label)" } == [
            "userAgent:com.gone.agent", "userAgent:com.home.ok", "userAgent:com.vendor.sync",
            "systemAgent:com.apple.foo", "systemAgent:com.keep.dict", "systemAgent:com.keep.emptydict",
            "systemDaemon:com.apple.helper", "systemDaemon:com.vendor.daemon", "systemDaemon:com.vendor.daemon",
            "systemDaemon:nolabel", "systemDaemon:org.noprogram", "systemDaemon:org.relative",
        ])
        #expect(items.allSatisfy { $0.enabledState == nil })
        #expect(items.allSatisfy { $0.id == $0.plistURL })
    }

    @Test func programFromProgramOrProgramArguments() async throws {
        let items = try await discover(fs)
        #expect(items.labeled("com.vendor.sync")?.program == "/Applications/Sync.app/Contents/MacOS/syncd")
        #expect(items.labeled("com.gone.agent")?.program == "~/Library/Gone/agent")
        #expect(items.labeled("com.apple.foo")?.program == "/usr/libexec/foo")
        #expect(items.labeled("org.noprogram")?.program == nil)
        #expect(items.labeled("org.noprogram")?.isBroken == false)
    }

    @Test func runAtLoadAndKeepAliveForms() async throws {
        let items = try await discover(fs)
        #expect(items.labeled("com.vendor.sync")?.runAtLoad == true)
        #expect(items.labeled("com.vendor.sync")?.keepAlive == true)
        #expect(items.labeled("com.gone.agent")?.runAtLoad == false)
        #expect(items.labeled("com.gone.agent")?.keepAlive == false)
        #expect(items.labeled("com.apple.foo")?.runAtLoad == false)
        #expect(items.labeled("com.keep.dict")?.keepAlive == true)
        #expect(items.labeled("com.keep.emptydict")?.keepAlive == false)
    }

    @Test func brokenDetectionExpandsTilde() async throws {
        let items = try await discover(fs)
        #expect(items.labeled("com.gone.agent")?.isBroken == true)
        #expect(items.labeled("com.home.ok")?.isBroken == false)
        #expect(items.labeled("com.vendor.sync")?.isBroken == false)
        #expect(items.labeled("nolabel")?.isBroken == true)
        // Relative program names resolve via PATH; they are never flagged.
        #expect(items.labeled("org.relative")?.isBroken == false)
    }

    @Test func appleFlag() async throws {
        let items = try await discover(fs)
        #expect(items.labeled("com.apple.foo")?.isApple == true)
        #expect(items.labeled("com.apple.helper")?.isApple == true)
        #expect(items.labeled("com.vendor.sync")?.isApple == false)
        #expect(items.labeled("org.noprogram")?.isApple == false)
    }

    @Test func ownerNameHeuristics() async throws {
        let items = try await discover(fs)
        #expect(items.labeled("com.vendor.sync")?.ownerAppName == "Sync")
        #expect(items.labeled("com.gone.agent")?.ownerAppName == "Gone")
        #expect(items.labeled("com.apple.foo")?.ownerAppName == "Apple")
        #expect(items.labeled("com.keep.dict")?.ownerAppName == "Keep")
        #expect(items.labeled("nolabel")?.ownerAppName == nil)
        #expect(BackgroundItemsInventory.ownerName(program: "/Users/x/Applications/My Tool.app/Contents/MacOS/t", label: "a.b") == "My Tool")
        // Only a direct child of an Applications folder counts; otherwise the label decides.
        #expect(BackgroundItemsInventory.ownerName(program: "/Applications/Utilities/Nested.app/Contents/x", label: "a.b") == "A")
        #expect(BackgroundItemsInventory.ownerName(program: "/Applications/.app/x", label: "single") == nil)
        #expect(BackgroundItemsInventory.ownerName(program: nil, label: "homebrew.mxcl.redis") == "Mxcl")
    }

    @Test func malformedAndNonPlistEntriesAreSkipped() async throws {
        let items = try await discover(fs)
        #expect(!items.contains { $0.plistURL.lastPathComponent == "broken.plist" })
        #expect(!items.contains { $0.plistURL.lastPathComponent == "array.plist" })
        #expect(!items.contains { $0.plistURL.lastPathComponent == "notes.txt" })
        #expect(!items.contains { $0.plistURL.lastPathComponent == "Folder.plist" })
    }

    @Test func privilegedHelperToolsAreProgramOnlyDaemons() async throws {
        let items = try await discover(fs)
        let helper = try #require(items.first { $0.plistURL.path == "/Library/PrivilegedHelperTools/com.vendor.daemon" })
        #expect(helper.domain == .systemDaemon)
        #expect(helper.label == "com.vendor.daemon")
        #expect(helper.program == "/Library/PrivilegedHelperTools/com.vendor.daemon")
        #expect(helper.runAtLoad == false)
        #expect(helper.keepAlive == false)
        #expect(helper.isBroken == false)
        #expect(helper.ownerAppName == "Vendor")
        #expect(!items.contains { $0.plistURL.path == "/Library/PrivilegedHelperTools/Subdir" })
    }

    @Test func enabledStateProviderIsConsulted() async throws {
        let log = EventLog()
        let provider = TableStateProvider(["com.vendor.sync": true, "com.vendor.daemon": false], log: log)
        let items = try await discover(fs, provider: provider)
        #expect(items.labeled("com.vendor.sync")?.enabledState == true)
        #expect(items.filter { $0.label == "com.vendor.daemon" }.allSatisfy { $0.enabledState == false })
        #expect(items.labeled("com.apple.foo")?.enabledState == nil)
        #expect(log.all.contains("userAgent:com.vendor.sync"))
        #expect(log.all.contains("systemDaemon:com.vendor.daemon"))
        #expect(log.all.count == items.count)
    }

    @Test func missingDirectoriesYieldNothing() async throws {
        let items = try await discover(["/Users/test/Documents/x.plist": launchdPlist(label: "a.b")])
        #expect(items.isEmpty)
    }

    @Test func parsesBinaryPlist() throws {
        let dict: [String: Any] = [
            "Label": "com.bin.item", "ProgramArguments": ["/opt/bin/x", "-v"], "RunAtLoad": true, "KeepAlive": false,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
        let item = try #require(BackgroundItemsInventory.parse(
            plist: data, url: URL(fileURLWithPath: "/Library/LaunchDaemons/com.bin.item.plist"),
            domain: .systemDaemon, home: testHome) { $0 == "/opt/bin/x" })
        #expect(item.label == "com.bin.item")
        #expect(item.program == "/opt/bin/x")
        #expect(item.runAtLoad)
        #expect(!item.keepAlive)
        #expect(!item.isBroken)
    }

    @Test func roundTripsThroughJSON() async throws {
        let items = try await discover(fs)
        let data = try JSONEncoder().encode(items)
        #expect(try JSONDecoder().decode([BackgroundItem].self, from: data) == items)
    }
}
