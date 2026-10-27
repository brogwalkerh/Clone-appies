import Foundation
import Testing
import CleanerCore
import CleanerCoreTesting
import PerformanceModule
@testable import maccleaner

@Suite("login-items list")
struct LoginItemsTests {
    private func plist(_ body: String) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \(body)
        </dict>
        </plist>
        """.utf8)
    }

    private func makeHome() throws -> FixtureBuilder {
        let home = try FixtureBuilder(name: "cli-login-items")
        let program = try home.file("Applications/Good.app/Contents/MacOS/Good", size: 16)
        try home.file("Library/LaunchAgents/com.example.good.plist", contents: plist("""
            <key>Label</key><string>com.example.good</string>
            <key>ProgramArguments</key><array><string>\(program.path)</string><string>--agent</string></array>
            <key>RunAtLoad</key><true/>
            """))
        try home.file("Library/LaunchAgents/com.example.broken.plist", contents: plist("""
            <key>Label</key><string>com.example.broken</string>
            <key>Program</key><string>\(home.url("Applications/Gone.app/Contents/MacOS/Gone").path)</string>
            <key>KeepAlive</key><true/>
            """))
        try home.file("Library/LaunchAgents/com.apple.sample.plist", contents: plist("""
            <key>Label</key><string>com.apple.sample</string>
            <key>Program</key><string>\(program.path)</string>
            """))
        try home.file("Library/LaunchAgents/notes.txt", contents: Data("not a plist".utf8))
        return home
    }

    /// Only the items under the fixture; the inventory also reads the real
    /// /Library directories, which may hold anything on a developer machine.
    private func fixtureItems(_ items: [BackgroundItem], home: FixtureBuilder) -> [BackgroundItem] {
        items.filter { $0.plistURL.path.hasPrefix(home.root.path) }
    }

    @Test("lists agents grouped by domain with badges, flagging the broken one")
    func list() async throws {
        let home = try makeHome()
        defer { try? home.remove() }
        let out = BufferSink()
        let all = try await LoginItemsList.run(inventory: BackgroundItemsInventory(fileSystem: LocalFileSystem()),
                                               home: home.root, options: LoginItemsOptions(),
                                               io: CommandIO(out: out, err: BufferSink()))
        let items = fixtureItems(all, home: home)
        #expect(items.map(\.label) == ["com.apple.sample", "com.example.broken", "com.example.good"])
        #expect(items.map(\.isBroken) == [false, true, false])
        #expect(items.allSatisfy { $0.domain == .userAgent })

        let rendered = LoginItemsList.render(items)
        #expect(rendered == """
        User agents (~/Library/LaunchAgents) — 3
          com.apple.sample    [apple]  -> \(home.url("Applications/Good.app/Contents/MacOS/Good").path)
          com.example.broken  [broken, keepAlive]  -> \(home.url("Applications/Gone.app/Contents/MacOS/Gone").path)
          com.example.good    [runAtLoad]  -> \(home.url("Applications/Good.app/Contents/MacOS/Good").path)

        3 items, 1 broken.
        """)
        #expect(out.text.contains("  com.example.broken  [broken, keepAlive]  -> "))
    }

    @Test("--broken-only keeps only broken items")
    func brokenOnly() async throws {
        let home = try makeHome()
        defer { try? home.remove() }
        var options = LoginItemsOptions()
        options.brokenOnly = true
        let out = BufferSink()
        let items = try await LoginItemsList.run(inventory: BackgroundItemsInventory(fileSystem: LocalFileSystem()),
                                                 home: home.root, options: options,
                                                 io: CommandIO(out: out, err: BufferSink()))
        let mine = fixtureItems(items, home: home)
        #expect(mine.map(\.label) == ["com.example.broken"])
        #expect(items.filter(\.isBroken).count == items.count)
        #expect(out.text.contains("com.example.broken  [broken, keepAlive]"))
    }

    @Test("--json prints a decodable array")
    func json() async throws {
        let home = try makeHome()
        defer { try? home.remove() }
        var options = LoginItemsOptions()
        options.json = true
        let out = BufferSink()
        let items = try await LoginItemsList.run(inventory: BackgroundItemsInventory(fileSystem: LocalFileSystem()),
                                                 home: home.root, options: options,
                                                 io: CommandIO(out: out, err: BufferSink()))
        let decoded = try ScanJSON.decode([BackgroundItem].self, from: Data(out.text.utf8))
        #expect(decoded == items)
        #expect(out.lines.count == 1)
    }

    @Test("renders an empty inventory")
    func empty() {
        #expect(LoginItemsList.render([]) == "No login or background items found.")
        #expect(LoginItemsList.filter([], brokenOnly: true).isEmpty)
    }
}
