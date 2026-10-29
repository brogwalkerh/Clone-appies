import Foundation
import Testing
import CleanerCore
import CleanerCoreTesting
import CleanupModule
import PerformanceModule
@testable import SmartCareModule

private func run(_ runner: ActionSetRunner, _ set: ActionSet, _ context: ScanContext) async -> (events: [ActionSetEvent], report: ActionSetReport?) {
    var events: [ActionSetEvent] = []
    var report: ActionSetReport?
    for await event in runner.run(set, context: context) {
        events.append(event)
        if case .completed(let r) = event { report = r }
    }
    return (events, report)
}

@Suite("ActionSet")
struct ActionSetTests {
    @Test func presetsUseRealScannerAndTaskIDs() {
        let scannerIDs = Set(CleanupScanners.all().map { type(of: $0).id })
        let taskIDs = Set(MaintenanceCatalog.all.map(\.id))
        for preset in ActionSetPresets.all {
            #expect(preset.validate(knownScannerIDs: scannerIDs, knownTaskIDs: taskIDs).isEmpty, "\(preset.name)")
        }
        #expect(Set(ActionSetPresets.all.map(\.id)).count == ActionSetPresets.all.count)
        #expect(ActionSetPresets.fridayClean.id.uuidString == "6F1D2C3B-0001-4A5B-9C8D-000000000001")
    }

    @Test func validateReportsEveryProblem() {
        let set = ActionSet(name: "  ", steps: [.clean(scannerIDs: [], includeCaution: false),
                                                 .clean(scannerIDs: ["nope"], includeCaution: false),
                                                 .maintenance(taskID: "maintenance.nope")])
        let problems = set.validate(knownScannerIDs: ["cleanup.logs"], knownTaskIDs: ["maintenance.flushDNS"])
        #expect(problems.count == 4)
        #expect(ActionSet(name: "x", steps: []).validate(knownScannerIDs: [], knownTaskIDs: []) == ["Add at least one step."])
    }

    @Test func codableRoundTrip() throws {
        let data = try JSONEncoder().encode(ActionSetPresets.all)
        #expect(try JSONDecoder().decode([ActionSet].self, from: data) == ActionSetPresets.all)
    }
}

@Suite("ActionSetRunner")
struct ActionSetRunnerTests {
    @Test func cleanRemovesSafeFindingsOnlyAndKeepsGoingAfterAFailure() async throws {
        let fixture = try FixtureBuilder()
        defer { try? fixture.remove() }
        let cache = try fixture.file("home/Library/Caches/app/blob", size: 100)
        let appCache = try fixture.file("home/Library/Caches/chat/blob", size: 30)
        let langFile = try fixture.file("home/Applications/X.app/fr.lproj", size: 7)
        let trash = fixture.url("trash/files")
        let scanner = FakeCleanupScanner(findings: [
            finding(cache.path, 100, risk: .safe, scanner: FakeCleanupScanner.id),
            finding(appCache.path, 30, risk: .caution, scanner: FakeCleanupScanner.id),
            finding(langFile.path, 7, risk: .risky, scanner: FakeCleanupScanner.id),
        ])
        let runner = ActionSetRunner(
            scanners: [scanner],
            remover: GuardedRemover(wrapping: TrashRemover(trashDirectory: trash), protectedPaths: .default),
            maintenance: MaintenanceRunner(commands: SucceedingCommandRunner(), helper: nil, home: fixture.url("home")))
        let set = ActionSet(name: "Test", steps: [
            .clean(scannerIDs: [FakeCleanupScanner.id], includeCaution: false),
            .maintenance(taskID: "maintenance.flushDNS"),          // needs the helper, which is missing
            .maintenance(taskID: "maintenance.clearFontCaches"),   // user-level
        ])
        let (events, report) = await run(runner, set, testContext(LocalFileSystem()))
        let result = try #require(report)

        #expect(result.results.count == 3)
        #expect(result.results[0].succeeded)
        #expect(result.results[0].bytesReclaimed == 100)
        #expect(result.results[0].manifest?.records.count == 1)
        #expect(!FileManager.default.fileExists(atPath: cache.path))
        #expect(FileManager.default.fileExists(atPath: appCache.path))
        #expect(FileManager.default.fileExists(atPath: langFile.path))

        #expect(!result.results[1].succeeded)
        #expect(result.results[1].message.contains(MaintenanceRunner.helperMissingMessage))
        #expect(result.results[2].succeeded)
        #expect(result.results[2].maintenance?.taskID == "maintenance.clearFontCaches")
        #expect(!result.succeeded)
        #expect(result.bytesReclaimed == 100)

        let starts = events.compactMap { event -> Int? in
            if case .stepStarted(let index, _) = event { return index }
            return nil
        }
        #expect(starts == [0, 1, 2])
    }

    @Test func includeCautionAlsoRemovesCautionFindings() async throws {
        let fixture = try FixtureBuilder()
        defer { try? fixture.remove() }
        let a = try fixture.file("data/a", size: 10)
        let b = try fixture.file("data/b", size: 20)
        let scanner = FakeCleanupScanner(findings: [finding(a.path, 10, risk: .safe), finding(b.path, 20, risk: .caution)])
        let runner = ActionSetRunner(scanners: [scanner], remover: TrashRemover(trashDirectory: fixture.url("trash/files")),
                                     maintenance: nil)
        let (_, report) = await run(runner, ActionSet(name: "x", steps: [.clean(scannerIDs: [FakeCleanupScanner.id], includeCaution: true)]),
                                    testContext(LocalFileSystem()))
        #expect(report?.bytesReclaimed == 30)
        #expect(!FileManager.default.fileExists(atPath: b.path))
    }

    @Test func dryRunTouchesNothing() async throws {
        let fixture = try FixtureBuilder()
        defer { try? fixture.remove() }
        let a = try fixture.file("data/a", size: 10)
        let runner = ActionSetRunner(scanners: [FakeCleanupScanner(findings: [finding(a.path, 10)])],
                                     remover: TrashRemover(trashDirectory: fixture.url("trash/files")),
                                     maintenance: nil, dryRun: true)
        let set = ActionSet(name: "x", steps: [.clean(scannerIDs: [FakeCleanupScanner.id], includeCaution: false),
                                               .maintenance(taskID: "maintenance.freeRAM")])
        let (_, report) = await run(runner, set, testContext(LocalFileSystem()))
        let result = try #require(report)
        #expect(result.succeeded)
        #expect(result.bytesReclaimed == 0)
        #expect(result.results[0].message.hasPrefix("Would remove 1 item"))
        #expect(result.results[1].message.hasPrefix("Would run"))
        #expect(FileManager.default.fileExists(atPath: a.path))
    }

    @Test func unknownIDsAndMissingMaintenanceFailTheirStep() async {
        let runner = ActionSetRunner(scanners: [], remover: TrashRemover(trashDirectory: URL(fileURLWithPath: "/tmp/never")),
                                     maintenance: nil)
        let set = ActionSet(name: "x", steps: [.clean(scannerIDs: ["cleanup.nope"], includeCaution: false),
                                               .maintenance(taskID: "maintenance.nope"),
                                               .maintenance(taskID: "maintenance.flushDNS")])
        let (_, report) = await run(runner, set, testContext())
        let messages = report?.results.map(\.message) ?? []
        #expect(report?.results.allSatisfy { !$0.succeeded } == true)
        #expect(messages[0].contains("cleanup.nope"))
        #expect(messages[1].contains("maintenance.nope"))
        #expect(messages[2].contains("not available"))
    }

    @Test func nothingToCleanSucceeds() async {
        let runner = ActionSetRunner(scanners: [FakeCleanupScanner(findings: [])],
                                     remover: TrashRemover(trashDirectory: URL(fileURLWithPath: "/tmp/never")), maintenance: nil)
        let (_, report) = await run(runner, ActionSet(name: "x", steps: [.clean(scannerIDs: [FakeCleanupScanner.id], includeCaution: false)]),
                                    testContext())
        #expect(report?.results.first?.succeeded == true)
        #expect(report?.results.first?.message == "Nothing to clean.")
    }
}
