import Foundation
import Testing
import CleanerCore
import CleanupModule
@testable import maccleaner

@Suite("Scanner registry")
struct ScannerRegistryTests {
    let registry = ScannerRegistry(scanners: [FakeCleanupScanner(), FakeClutterScanner(), FailingScanner()])

    @Test("returns everything when unfiltered")
    func unfiltered() throws {
        #expect(try registry.filtered().map(\.id) == ["test.cleanup", "test.clutter", "test.failing"])
    }

    @Test("filters by module")
    func byModule() throws {
        #expect(try registry.filtered(module: .clutter).map(\.id) == ["test.clutter"])
        #expect(try registry.filtered(module: .protection).isEmpty)
    }

    @Test("filters by scanner id")
    func byID() throws {
        #expect(try registry.filtered(scannerIDs: ["test.failing", "test.cleanup"]).map(\.id)
                == ["test.cleanup", "test.failing"])
    }

    @Test("module and id filters intersect")
    func intersection() throws {
        #expect(try registry.filtered(module: .cleanup, scannerIDs: ["test.cleanup", "test.clutter"]).map(\.id)
                == ["test.cleanup"])
    }

    @Test("rejects unknown scanner ids")
    func unknownID() {
        #expect(throws: RegistryError.unknownScanner("nope", available: ["test.cleanup", "test.clutter", "test.failing"])) {
            try registry.filtered(scannerIDs: ["nope"])
        }
    }

    @Test("drops duplicate ids, keeping the first")
    func duplicates() {
        let duplicated = ScannerRegistry(scanners: [FakeCleanupScanner(), FakeCleanupScanner(), FakeClutterScanner()])
        #expect(duplicated.scanners.map(\.id) == ["test.cleanup", "test.clutter"])
        #expect(duplicated.scanner(withID: "test.clutter") != nil)
        #expect(duplicated.scanner(withID: "missing") == nil)
    }

    @Test("built-in registry has the Cleanup scanners plus the demo scanner, with unique ids")
    func builtIn() {
        let ids = ScannerRegistry.builtIn().scanners.map(\.id)
        #expect(ids.contains(DemoScanner.id))
        #expect(ids.last == DemoScanner.id)
        for scanner in CleanupScanners.all() {
            #expect(ids.contains(scanner.id))
        }
        #expect(Set(ids).count == ids.count)
    }

    @Test("list-scanners renders a table and JSON")
    func listScanners() throws {
        let entries = ListScanners.entries(registry)
        #expect(entries == [
            .init(id: "test.cleanup", displayName: "Fake Cleanup", module: .cleanup),
            .init(id: "test.clutter", displayName: "Fake Clutter", module: .clutter),
            .init(id: "test.failing", displayName: "Failing", module: .performance),
        ])
        let table = BufferSink()
        try ListScanners.run(registry: registry, json: false, io: CommandIO(out: table, err: BufferSink()))
        #expect(table.text == """
        ID            Name          Module
        ----------------------------------------
        test.cleanup  Fake Cleanup  cleanup
        test.clutter  Fake Clutter  clutter
        test.failing  Failing       performance
        """)

        let json = BufferSink()
        try ListScanners.run(registry: registry, json: true, io: CommandIO(out: json, err: BufferSink()))
        let decoded = try ScanJSON.decode([ListScanners.Entry].self, from: Data(json.text.utf8))
        #expect(decoded == entries)
    }
}
