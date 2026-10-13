import Foundation
import Testing
import CleanerCore
import CleanerCoreTesting
@testable import maccleaner

@Suite("End to end: scan, remove --dry-run, remove, undo", .serialized)
struct EndToEndTests {
    private func makeHome() throws -> FixtureBuilder {
        let fixture = try FixtureBuilder(name: "cli-home")
        try fixture.file("scratch.tmp", size: 1_000)
        try fixture.file("Library/Logs/app.log", size: 2_000)
        try fixture.file(".Trash/old.txt", size: 500)
        try fixture.file(".Trash/Folder/inner.bin", size: 300)
        try fixture.file("Documents/keep.pdf", size: 4_000)
        return fixture
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    @Test("scan, dry run, remove into a temp trash, undo restores everything")
    func scanRemoveUndo() async throws {
        let home = try makeHome()
        defer { try? home.remove() }
        let trashRoot = try FixtureBuilder(name: "cli-trash")
        defer { try? trashRoot.remove() }
        let trashDirectory = trashRoot.url("Trash/files")

        let expectedPaths: Set<String> = [
            home.url("scratch.tmp").path,
            home.url("Library/Logs/app.log").path,
            home.url(".Trash/old.txt").path,
            home.url(".Trash/Folder").path,
        ]
        let context = ScanContext(fileSystem: LocalFileSystem(), home: home.root)

        // scan --json: no progress on stderr, a decodable document on stdout.
        let jsonOut = BufferSink(), jsonErr = BufferSink()
        var scanOptions = ScanOptions()
        scanOptions.json = true
        let outcome = await ScanRunner.run(context: context, scanners: [DemoScanner()],
                                           options: scanOptions, io: CommandIO(out: jsonOut, err: jsonErr))
        #expect(outcome.failures.isEmpty)
        #expect(outcome.skippedRisky == 0)
        #expect(jsonErr.lines.isEmpty)
        #expect(Set(outcome.document.findings.map(\.path.path)) == expectedPaths)
        #expect(outcome.document.summary.totalFindings == 4)
        #expect(outcome.document.summary.totalBytes == 3_800)
        #expect(outcome.document.summary.byCategory == [
            DemoScanner.temporaryFiles.id: 1_000,
            DemoScanner.logFiles.id: 2_000,
            DemoScanner.trash.id: 800,
        ])
        let folder = try #require(outcome.document.findings.first { $0.path.lastPathComponent == "Folder" })
        #expect(folder.isDirectory)
        #expect(folder.sizeBytes == 300)

        let document = try ScanJSON.decode(ScanDocument.self, from: Data(jsonOut.text.utf8))
        #expect(document.summary == outcome.document.summary)
        #expect(document.findings.map(\.id) == outcome.document.findings.map(\.id))
        #expect(try ScanJSON.encode(document) == jsonOut.text)

        // scan (table): progress lines on stderr, table on stdout.
        let tableOut = BufferSink(), tableErr = BufferSink()
        _ = await ScanRunner.run(context: context, scanners: [DemoScanner()],
                                 options: ScanOptions(), io: CommandIO(out: tableOut, err: tableErr))
        #expect(tableErr.lines.first == "[started]  cli.demo")
        #expect(tableErr.lines.last == "[finished] cli.demo: 4 findings, 3.8 KB")
        #expect(tableOut.text.hasPrefix("Category         Count       Size\n---------------------------------\n"))
        #expect(tableOut.text.contains("Total                4     3.8 KB"))
        #expect(tableOut.text.contains("1. [safe]     2 KB  \(home.url("Library/Logs/app.log").path)"))
        #expect(tableOut.text.contains("[caution] 300 B  \(home.url(".Trash/Folder").path)/"))

        let remover = GuardedRemover(
            wrapping: TrashRemover(fileSystem: LocalFileSystem(), trashDirectory: trashDirectory),
            protectedPaths: .default)

        // remove --dry-run: lists, touches nothing, never prompts.
        let dryOut = BufferSink()
        var removeOptions = RemoveOptions()
        removeOptions.dryRun = true
        let dry = try await RemoveRunner.run(document: document, options: removeOptions, remover: remover,
                                             confirm: { Issue.record("dry run must not prompt"); return false },
                                             io: CommandIO(out: dryOut, err: BufferSink()))
        #expect(dry.manifest == nil)
        #expect(dry.manifestURL == nil)
        #expect(dry.selected.count == 4)
        #expect(dryOut.lines.first == "Would move to Trash 4 items (3.8 KB):")
        #expect(dryOut.lines.last == "Dry run: nothing was removed.")
        for path in expectedPaths {
            #expect(exists(URL(fileURLWithPath: path)), "\(path) must survive a dry run")
        }

        // Declining the prompt removes nothing.
        let declinedOut = BufferSink()
        removeOptions.dryRun = false
        let declined = try await RemoveRunner.run(document: document, options: removeOptions, remover: remover,
                                                  confirm: { false },
                                                  io: CommandIO(out: declinedOut, err: BufferSink()))
        #expect(declined.manifest == nil)
        #expect(declinedOut.lines.last == "Aborted.")
        #expect(exists(home.url("scratch.tmp")))

        // remove --yes --manifest-out: moves into the temp trash and writes the manifest.
        let manifestURL = trashRoot.url("manifests/run.json")
        removeOptions.assumeYes = true
        removeOptions.manifestOut = manifestURL
        let removeOut = BufferSink()
        let removed = try await RemoveRunner.run(document: document, options: removeOptions, remover: remover,
                                                 confirm: { Issue.record("--yes must not prompt"); return false },
                                                 io: CommandIO(out: removeOut, err: BufferSink()))
        let manifest = try #require(removed.manifest)
        #expect(removed.manifestURL == manifestURL)
        #expect(manifest.mode == .trash)
        #expect(manifest.records.count == 4)
        #expect(manifest.records.filter(\.succeeded).count == 4)
        #expect(manifest.bytesReclaimed == 3_800)
        #expect(removeOut.text.contains("Removed 4 of 4 items, reclaimed 3.8 KB."))
        #expect(removeOut.text.contains("Manifest written to \(manifestURL.path)"))
        for path in expectedPaths {
            #expect(!exists(URL(fileURLWithPath: path)), "\(path) must be gone after removal")
        }
        #expect(exists(home.url("Documents/keep.pdf")))
        #expect(exists(trashDirectory.appendingPathComponent("scratch.tmp")))
        #expect(exists(trashDirectory.appendingPathComponent("Folder/inner.bin")))

        // undo --manifest: reads the manifest back from disk and restores everything.
        let loaded = try ScanJSON.decode(RemovalManifest.self, from: manifestURL)
        #expect(loaded.id == manifest.id)
        #expect(loaded.records.map(\.trashedTo) == manifest.records.map(\.trashedTo))
        let undoOut = BufferSink()
        let undone = try await UndoRunner.run(manifest: loaded, remover: remover,
                                              io: CommandIO(out: undoOut, err: BufferSink()))
        #expect(undone.restored == 4)
        #expect(undone.failed == 0)
        #expect(undoOut.lines == ["Restored 4 items, 0 failed."])
        for path in expectedPaths {
            #expect(exists(URL(fileURLWithPath: path)), "\(path) must be restored by undo")
        }
        let restoredSize = try FileManager.default.attributesOfItem(atPath: home.url("Library/Logs/app.log").path)[.size] as? Int
        #expect(restoredSize == 2_000)
        #expect(exists(home.url(".Trash/Folder/inner.bin")))
    }

    @Test("risky findings are skipped unless --include-risky")
    func riskyFiltering() async throws {
        let (selected, skipped, nested) = RemoveRunner.selectFindings(from: Fixtures.document, includeRisky: false)
        #expect(skipped == 1)
        #expect(nested == 0)
        #expect(!selected.contains { $0.risk == .risky })
        let (all, none, _) = RemoveRunner.selectFindings(from: Fixtures.document, includeRisky: true)
        #expect(none == 0)
        #expect(all.count == 4)

        // The scan side hides risky findings from its output the same way.
        let home = try makeHome()
        defer { try? home.remove() }
        let out = BufferSink()
        var options = ScanOptions()
        options.json = true
        let outcome = await ScanRunner.run(context: ScanContext(fileSystem: LocalFileSystem(), home: home.root),
                                           scanners: [DemoScanner()], options: options,
                                           io: CommandIO(out: out, err: BufferSink()))
        #expect(outcome.skippedRisky == 0)
    }

    @Test("findings nested under another selected finding are removed only once, via the parent")
    func nestedFindings() async throws {
        let home = try makeHome()
        defer { try? home.remove() }
        let trashRoot = try FixtureBuilder(name: "cli-trash-nested")
        defer { try? trashRoot.remove() }
        let category = FindingCategory(id: "test.nested", displayName: "Nested", module: .cleanup)
        let parent = Finding(path: home.url("Library/Logs"), sizeBytes: 2_000, category: category,
                             scannerID: "test", risk: .safe, isDirectory: true)
        let child = Finding(path: home.url("Library/Logs/app.log"), sizeBytes: 2_000, category: category,
                            scannerID: "test", risk: .safe)
        let other = Finding(path: home.url("scratch.tmp"), sizeBytes: 1_000, category: category,
                            scannerID: "test", risk: .safe)
        let document = ScanDocument(findings: [child, parent, other], duration: 0)

        let (selected, _, nested) = RemoveRunner.selectFindings(from: document, includeRisky: false)
        #expect(nested == 1)
        #expect(Set(selected.map(\.path.path)) == [parent.path.path, other.path.path])

        let remover = GuardedRemover(
            wrapping: TrashRemover(fileSystem: LocalFileSystem(), trashDirectory: trashRoot.url("files")),
            protectedPaths: .default)
        var options = RemoveOptions()
        options.assumeYes = true
        options.manifestOut = trashRoot.url("manifest.json")
        let out = BufferSink()
        let outcome = try await RemoveRunner.run(document: document, options: options, remover: remover,
                                                 confirm: { false }, io: CommandIO(out: out, err: BufferSink()))
        #expect(outcome.skippedNested == 1)
        #expect(out.text.contains("Skipped 1 finding nested under other selected items."))
        let manifest = try #require(outcome.manifest)
        #expect(manifest.records.count == 2)
        #expect(manifest.records.filter(\.succeeded).count == 2)
        #expect(!exists(home.url("Library/Logs/app.log")))
        #expect(exists(home.url("Documents/keep.pdf")))
    }

    @Test("permanent removal requires --yes")
    func permanentNeedsYes() async throws {
        var options = RemoveOptions()
        options.mode = .permanent
        let remover = GuardedRemover(wrapping: TrashRemover(fileSystem: LocalFileSystem(),
                                                            trashDirectory: FileManager.default.temporaryDirectory),
                                     protectedPaths: .default)
        await #expect(throws: RemoveError.permanentRequiresYes) {
            _ = try await RemoveRunner.run(document: Fixtures.document, options: options, remover: remover,
                                           confirm: { true }, io: CommandIO(out: BufferSink(), err: BufferSink()))
        }
    }

    @Test("scanner failures are reported and surfaced for --strict")
    func failures() async throws {
        let home = try makeHome()
        defer { try? home.remove() }
        let out = BufferSink(), err = BufferSink()
        let outcome = await ScanRunner.run(context: ScanContext(fileSystem: LocalFileSystem(), home: home.root),
                                           scanners: [FailingScanner(), DemoScanner()], options: ScanOptions(),
                                           io: CommandIO(out: out, err: err))
        #expect(outcome.failures.map(\.scannerID) == ["test.failing"])
        #expect(err.lines.contains { $0.hasPrefix("[failed]   test.failing: ") })
        #expect(out.lines.last == "1 scanner failed; see stderr.")
        #expect(outcome.document.findings.count == 4)
    }
}
