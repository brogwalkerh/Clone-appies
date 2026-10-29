import Foundation
import Testing
import CleanerCore
import CleanerCoreTesting
import ProtectionModule
import SmartCareModule
@testable import maccleaner

private let eicar = #"X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*"#

private func makeHome() throws -> FixtureBuilder {
    let home = try FixtureBuilder(name: "smartcare-home")
    try home.file("Library/Caches/com.example.app/blob.bin", size: 4_000)
    try home.file("Library/Logs/com.example.app/app.log", size: 2_000)
    try home.file(".Trash/old.txt", size: 500)
    try home.file("Downloads/eicar.com", contents: Data(eicar.utf8))
    try home.file("Documents/keep.pdf", size: 9_000)
    return home
}

private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
}

@Suite("smart-care", .serialized)
struct SmartCareCommandTests {
    @Test func modulesFollowSmartCareOrderWithoutPrivacyOrDemo() {
        let modules = SmartCareRun.modules(registry: .builtIn(), malware: SignatureDatabase.bundledStarter())
        #expect(modules.map(\.0) == [.cleanup, .protection, .performance, .applications, .clutter])
        let ids = modules.flatMap { $0.1.map(\.id) }
        #expect(!ids.contains(DemoScanner.id))
        #expect(!ids.contains { $0.hasPrefix("privacy.") })
        #expect(modules.first { $0.0 == .protection }?.1.map(\.id) == [MalwareScanner.id])
        #expect(!SmartCareRun.modules(registry: .builtIn(), malware: nil).contains { $0.0 == .protection })
    }

    @Test func jsonReportsEveryModuleAndSelectsOnlyCleanableJunk() async throws {
        let home = try makeHome()
        defer { try? home.remove() }
        let out = BufferSink(), err = BufferSink()
        var options = SmartCareOptions()
        options.json = true
        let activity = InMemoryActivityStore()
        let outcome = try await SmartCareRun.run(
            context: ScanContext(fileSystem: LocalFileSystem(), home: home.root),
            modules: SmartCareRun.modules(registry: .builtIn(), malware: SignatureDatabase.bundledStarter()),
            options: options, remover: TrashRemover(trashDirectory: home.url("never")), activity: activity,
            confirm: { false }, io: CommandIO(out: out, err: err))

        #expect(err.lines.isEmpty)
        let document = try ScanJSON.decode(SmartCareDocument.self, from: Data(out.text.utf8))
        #expect(document.modules.map(\.module) == ["cleanup", "protection", "performance", "applications", "clutter"])
        let protection = try #require(document.modules.first { $0.module == "protection" })
        #expect(protection.findings == 1)
        #expect(protection.reviewOnly)
        let selected = Set(document.selected.map(\.path.lastPathComponent))
        #expect(selected.contains("old.txt"))
        #expect(!selected.contains("eicar.com"))
        #expect(!selected.contains("keep.pdf"))
        #expect(document.reclaimableBytes == document.selected.reduce(0) { $0 + $1.sizeBytes })
        #expect(outcome.removal == nil)
        // Scanning records one scan event per module and removes nothing.
        let events = try await activity.events(since: nil)
        #expect(events.map(\.kind) == Array(repeating: .scan, count: 5))
        #expect(exists(home.url(".Trash/old.txt")))
    }

    @Test func runRemovesTheSelectionAndRecordsActivity() async throws {
        let home = try makeHome()
        defer { try? home.remove() }
        let trash = try FixtureBuilder(name: "smartcare-trash")
        defer { try? trash.remove() }
        let out = BufferSink(), err = BufferSink()
        var options = SmartCareOptions()
        options.remove = true
        options.assumeYes = true
        options.manifestOut = trash.url("manifest.json")
        let activity = InMemoryActivityStore()
        let outcome = try await SmartCareRun.run(
            context: ScanContext(fileSystem: LocalFileSystem(), home: home.root),
            modules: SmartCareRun.modules(registry: .builtIn(), malware: SignatureDatabase.bundledStarter()),
            options: options,
            remover: GuardedRemover(wrapping: TrashRemover(fileSystem: HomeFileSystem(home: home.root),
                                                           trashDirectory: trash.url("Trash/files")),
                                    protectedPaths: .default),
            activity: activity, confirm: { false }, io: CommandIO(out: out, err: err))

        let manifest = try #require(outcome.removal?.manifest)
        #expect(manifest.records.allSatisfy { $0.succeeded })
        #expect(!exists(home.url(".Trash/old.txt")))
        // The Trash item was emptied, not moved into the temp trash.
        let emptied = try #require(manifest.records.first { $0.finding.path.lastPathComponent == "old.txt" })
        #expect(emptied.trashedTo == nil)
        #expect(exists(home.url("Downloads/eicar.com")))
        #expect(exists(home.url("Documents/keep.pdf")))
        #expect(exists(trash.url("manifest.json")))
        #expect(out.text.contains("Smart Care ("))
        #expect(out.text.contains("Removed \(manifest.records.count) of \(manifest.records.count)"))

        let events = try await activity.events(since: nil)
        let removals = events.filter { $0.kind == .removal }
        #expect(removals.map(\.module) == [.cleanup])
        #expect(removals.first?.bytes == manifest.bytesReclaimed)
    }

    @Test func tableMarksReviewOnlyModules() {
        let report = SmartCareReport(startedAt: .now, duration: 2.04, summaries: [
            .cleanup: ScanSummary(totalFindings: 3, totalBytes: 3_000, byCategory: [:], duration: 1),
            .protection: ScanSummary(totalFindings: 1, totalBytes: 68, byCategory: [:], duration: 1),
            .clutter: ScanSummary(totalFindings: 0, totalBytes: 0, byCategory: [:], duration: 1),
        ], findings: [], failures: ["x": "boom"])
        let lines = SmartCareRun.table(report, policy: .default).split(separator: "\n").map(String.init)
        #expect(lines[0] == "Smart Care (2.0 s)")
        #expect(lines[1] == "  Cleanup     3 items  3 KB")
        #expect(lines[2] == "  Protection  1 threat   (quarantine with `maccleaner protect scan`)")
        #expect(lines[3] == "  My Clutter  0 items  0 B")
        #expect(lines[4] == "1 scanner failed; see stderr.")
    }
}

@Suite("actions")
struct ActionsCommandTests {
    @Test func savedSetsJoinAndOverridePresets() throws {
        let data = try FixtureBuilder(name: "actions-data")
        defer { try? data.remove() }
        let storage = SmartCareStorage(directory: data.root)
        var edited = ActionSetPresets.fridayClean
        edited.name = "My Friday"
        let mine = ActionSet(name: "Logs only", steps: [.clean(scannerIDs: ["cleanup.logs"], includeCaution: false)])
        try storage.actionSets.save([edited, mine])

        let sets = ActionSets.available(storage: storage)
        #expect(sets.map(\.name) == ["Developer cleanup", "Quick tune-up", "My Friday", "Logs only"])
        #expect(try ActionSets.find("logs ONLY", in: sets).id == mine.id)
        #expect(try ActionSets.find(edited.id.uuidString, in: sets).name == "My Friday")
        #expect(throws: (any Error).self) { try ActionSets.find("nope", in: sets) }
    }

    @Test func runReportsStepsRecordsActivityAndHonoursDecline() async throws {
        let home = try FixtureBuilder(name: "actions-home")
        defer { try? home.remove() }
        try home.file("Library/Logs/com.example.app/app.log", size: 2_000)
        let set = ActionSet(name: "Logs then DNS", steps: [.clean(scannerIDs: ["cleanup.logs"], includeCaution: false),
                                                           .maintenance(taskID: "maintenance.flushDNS")])
        let runner = ActionSetRunner(scanners: ScannerRegistry.builtIn().scanners,
                                     remover: TrashRemover(trashDirectory: home.url("trash/files")), maintenance: nil)
        let context = ScanContext(fileSystem: LocalFileSystem(), home: home.root)

        let declined = BufferSink()
        let none = try await ActionSets.run(set, runner: runner, context: context, assumeYes: false, activity: nil,
                                            confirm: { false }, io: CommandIO(out: declined, err: BufferSink()))
        #expect(none == nil)
        #expect(declined.lines.last == "Aborted.")
        #expect(exists(home.url("Library/Logs/com.example.app/app.log")))

        let out = BufferSink()
        let activity = InMemoryActivityStore()
        let report = try #require(try await ActionSets.run(set, runner: runner, context: context, assumeYes: true,
                                                           activity: activity, confirm: { false },
                                                           io: CommandIO(out: out, err: BufferSink())))
        #expect(report.results.map(\.succeeded) == [true, false])
        #expect(!exists(home.url("Library/Logs/com.example.app/app.log")))
        #expect(out.lines.contains { $0.hasPrefix("[done] 1. Removed") })
        #expect(out.lines.contains { $0.hasPrefix("[failed] 2.") })
        #expect(out.lines.contains("  2. run Flush DNS Cache (needs the app's helper)"))
        let kinds = try await activity.events(since: nil).map(\.kind)
        #expect(kinds.contains(.removal))
        #expect(kinds.contains(.actionSet))
    }
}

@Suite("activity")
struct ActivityCommandTests {
    @Test func textAndJSON() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        let now = ISO8601DateFormatter().date(from: "2026-10-29T12:00:00Z")!
        let events = [
            ActivityEvent(date: now.addingTimeInterval(-3_600), kind: .removal, module: .cleanup, title: "Cleaned Cleanup",
                          bytes: 2_000_000, items: 20),
            ActivityEvent(date: now.addingTimeInterval(-60), kind: .quarantine, module: .protection, title: "Quarantined 1 threat",
                          bytes: 68, items: 1),
        ]
        let out = BufferSink()
        try ActivityReport.write(events: events, now: now, calendar: calendar, weeks: 2, limit: 5, json: false,
                                 io: CommandIO(out: out, err: BufferSink()))
        #expect(out.lines[0] == "Reclaimed: 2 MB (2 MB in the last 30 days)")
        #expect(out.lines[1] == "Items removed: 20   Threats quarantined: 1   Maintenance runs: 0")
        #expect(out.lines[2] == "Time saved: about 11 min")
        #expect(out.lines.contains("  2026-10-26  2 MB"))
        #expect(out.lines.contains("  2026-10-29 11:59  Quarantined 1 threat  68 B"))

        let json = BufferSink()
        try ActivityReport.write(events: events, now: now, calendar: calendar, weeks: 2, limit: 1, json: true,
                                 io: CommandIO(out: json, err: BufferSink()))
        let document = try ScanJSON.decode(ActivityDocument.self, from: Data(json.text.utf8))
        #expect(document.bytesReclaimed == 2_000_000)
        #expect(document.weeks.count == 2)
        #expect(document.weeks.last?.bytes == ["cleanup": 2_000_000])
        #expect(document.recent.map(\.kind) == [.quarantine])

        let empty = BufferSink()
        try ActivityReport.write(events: [], now: now, calendar: calendar, weeks: 2, limit: 5, json: false,
                                 io: CommandIO(out: empty, err: BufferSink()))
        #expect(empty.lines == ["No activity yet. Run `maccleaner smart-care` to start."])
    }

    @Test func durations() {
        #expect(ActivityReport.duration(30) == "under a minute")
        #expect(ActivityReport.duration(45 * 60) == "45 min")
        #expect(ActivityReport.duration(2 * 3_600) == "2 h")
        #expect(ActivityReport.duration(3 * 3_600 + 20 * 60) == "3 h 20 min")
    }
}

/// `LocalFileSystem` with a fixture home, so the remover treats `<fixture>/.Trash` as the Trash.
private struct HomeFileSystem: FileSystem {
    let home: URL
    private let local = LocalFileSystem()
    func exists(_ url: URL) -> Bool { local.exists(url) }
    func attributes(of url: URL) throws -> FileAttributes { try local.attributes(of: url) }
    func children(of url: URL) throws -> [URL] { try local.children(of: url) }
    func contents(of url: URL) throws -> Data { try local.contents(of: url) }
    func homeDirectory() -> URL { home }
    func temporaryDirectory() -> URL { local.temporaryDirectory() }
}
