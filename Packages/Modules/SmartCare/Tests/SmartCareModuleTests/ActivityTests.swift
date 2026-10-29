import Foundation
import Testing
import CleanerCore
import CleanerCoreTesting
import PerformanceModule
@testable import SmartCareModule

private func manifest(bytes: [Int64], failed: Int = 0, at date: Date) -> RemovalManifest {
    var records = bytes.map { size in
        RemovalRecord(finding: finding("/tmp/a/\(UUID().uuidString)", size), trashedTo: nil, succeeded: true, error: nil)
    }
    for _ in 0..<failed {
        records.append(RemovalRecord(finding: finding("/tmp/a/f", 999), trashedTo: nil, succeeded: false, error: "x"))
    }
    return RemovalManifest(startedAt: date, mode: .trash, records: records)
}

@Suite("ActivityEvent factories")
struct ActivityEventTests {
    @Test func removalCountsOnlySucceededRecords() {
        let event = ActivityEvent.removal(manifest(bytes: [100, 50], failed: 1, at: date("2026-10-20T10:00:00Z")), module: .cleanup)
        #expect(event.kind == .removal)
        #expect(event.bytes == 150)
        #expect(event.items == 2)
        #expect(event.date == date("2026-10-20T10:00:00Z"))
        #expect(event.reference != nil)
    }

    @Test func maintenanceUsesCatalogNameAndIgnoresFailures() {
        let ok = ActivityEvent.maintenance(MaintenanceResult(taskID: "maintenance.flushDNS", succeeded: true,
                                                             message: "", bytesReclaimed: nil, duration: 1))
        #expect(ok.title == MaintenanceCatalog.task(id: "maintenance.flushDNS")?.name)
        #expect(ok.items == 1)
        let failed = ActivityEvent.maintenance(MaintenanceResult(taskID: "maintenance.freeRAM", succeeded: false,
                                                                 message: "", bytesReclaimed: 500, duration: 1))
        #expect(failed.items == 0)
        #expect(failed.bytes == 0)
    }
}

@Suite("JSONLinesActivityStore")
struct JSONLinesActivityStoreTests {
    @Test func appendsReadsAndFilters() async throws {
        let fixture = try FixtureBuilder()
        defer { try? fixture.remove() }
        let url = fixture.url("support/activity.jsonl")
        let store = JSONLinesActivityStore(fileURL: url)
        let early = ActivityEvent(date: date("2026-10-01T00:00:00Z"), kind: .scan, module: .cleanup, title: "a")
        let late = ActivityEvent(date: date("2026-10-20T00:00:00Z"), kind: .scan, module: .clutter, title: "b")
        try await store.append([late])
        try await store.append([early])

        // A second instance (another process) sees both, oldest first.
        let other = JSONLinesActivityStore(fileURL: url)
        #expect(try await other.events(since: nil) == [early, late])
        #expect(try await other.events(since: date("2026-10-10T00:00:00Z")) == [late])

        try await other.removeAll()
        #expect(try await store.events(since: nil).isEmpty)
    }

    @Test func skipsCorruptLines() async throws {
        let fixture = try FixtureBuilder()
        defer { try? fixture.remove() }
        let url = fixture.url("activity.jsonl")
        let store = JSONLinesActivityStore(fileURL: url)
        let event = ActivityEvent(date: date("2026-10-01T00:00:00Z"), kind: .scan, module: .cleanup, title: "ok")
        try await store.append([event])
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"torn\":".utf8))   // no newline, as after a crash
        try handle.close()
        try await store.append([event].map { _ in
            ActivityEvent(date: date("2026-10-02T00:00:00Z"), kind: .scan, module: .clutter, title: "after")
        })
        let titles = try await JSONLinesActivityStore(fileURL: url).events(since: nil).map(\.title)
        #expect(titles == ["ok", "after"])
    }

    @Test func compactsToTheNewestEventsOnOpen() async throws {
        let fixture = try FixtureBuilder()
        defer { try? fixture.remove() }
        let url = fixture.url("activity.jsonl")
        let writer = JSONLinesActivityStore(fileURL: url, maxEvents: 100)
        let base = date("2026-01-01T00:00:00Z")
        try await writer.append((0..<10).map {
            ActivityEvent(date: base.addingTimeInterval(Double($0)), kind: .scan, module: .cleanup, title: "\($0)")
        })
        let reader = JSONLinesActivityStore(fileURL: url, maxEvents: 3)
        #expect(try await reader.events(since: nil).map(\.title) == ["7", "8", "9"])
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 3)
    }
}

@Suite("ActivityStats")
struct ActivityStatsTests {
    private let calendar = utcCalendar()
    // Thursday; its Monday-based week starts 2026-10-26.
    private let now = date("2026-10-29T12:00:00Z")

    @Test func emptyHistory() {
        let stats = ActivityStats(events: [], now: now, calendar: calendar, weeks: 4)
        #expect(stats.bytesReclaimed == 0)
        #expect(stats.weeks.count == 4)
        #expect(stats.weeks.last?.start == date("2026-10-26T00:00:00Z"))
        #expect(stats.weeks.first?.start == date("2026-10-05T00:00:00Z"))
        #expect(stats.weeks.allSatisfy { $0.totalBytes == 0 })
        #expect(stats.estimatedTimeSaved == 0)
        #expect(stats.lastRemoval == nil)
    }

    @Test func totalsBucketsAndUndo() {
        let events: [ActivityEvent] = [
            ActivityEvent(date: date("2026-10-27T09:00:00Z"), kind: .removal, module: .cleanup, title: "", bytes: 1_000, items: 10),
            ActivityEvent(date: date("2026-10-28T09:00:00Z"), kind: .removal, module: .clutter, title: "", bytes: 5_000, items: 1),
            ActivityEvent(date: date("2026-10-28T10:00:00Z"), kind: .undo, module: .clutter, title: "", bytes: 2_000, items: 1),
            ActivityEvent(date: date("2026-10-14T09:00:00Z"), kind: .removal, module: .cleanup, title: "", bytes: 300, items: 3),
            // Older than the 4-week window and the 30-day window: counts all time only.
            ActivityEvent(date: date("2026-08-01T09:00:00Z"), kind: .removal, module: .applications, title: "", bytes: 7, items: 1),
            ActivityEvent(date: date("2026-10-20T09:00:00Z"), kind: .maintenance, module: .performance, title: "", bytes: 40, items: 1),
            ActivityEvent(date: date("2026-10-21T09:00:00Z"), kind: .quarantine, module: .protection, title: "", bytes: 9_999, items: 2),
            ActivityEvent(date: date("2026-10-22T09:00:00Z"), kind: .scan, module: .cleanup, title: "", bytes: 123, items: 4),
            ActivityEvent(date: date("2026-10-25T09:00:00Z"), kind: .scan, module: .cleanup, title: "", bytes: 123, items: 4),
        ]
        let stats = ActivityStats(events: events, now: now, calendar: calendar, weeks: 4)
        #expect(stats.bytesReclaimed == 1_000 + 5_000 - 2_000 + 300 + 7 + 40)
        #expect(stats.bytesReclaimedLast30Days == 1_000 + 5_000 - 2_000 + 300 + 40)
        #expect(stats.itemsRemoved == 10 + 1 - 1 + 3 + 1)
        #expect(stats.threatsQuarantined == 2)
        #expect(stats.maintenanceRuns == 1)
        #expect(stats.lastScan[.cleanup] == date("2026-10-25T09:00:00Z"))
        #expect(stats.lastRemoval == date("2026-10-28T09:00:00Z"))
        #expect(stats.lastMaintenance == date("2026-10-20T09:00:00Z"))

        let thisWeek = stats.weeks[3]
        #expect(thisWeek.bytesByModule[.cleanup] == 1_000)
        #expect(thisWeek.bytesByModule[.clutter] == 3_000)
        #expect(stats.weeks[2].bytesByModule[.performance] == 40)   // week of Oct 19
        #expect(stats.weeks[1].bytesByModule[.cleanup] == 300)      // week of Oct 12
        #expect(stats.weeks[0].totalBytes == 0)

        let expectedTime = TimeSavedModel.perRemovedItem * 15 + TimeSavedModel.perMaintenanceTask
            + TimeSavedModel.perThreat * 2 + TimeSavedModel.perScan * 2
        #expect(stats.estimatedTimeSaved == expectedTime)
    }

    @Test func undoNeverDrivesTotalsNegative() {
        let events = [ActivityEvent(date: now, kind: .undo, module: .cleanup, title: "", bytes: 500, items: 5)]
        let stats = ActivityStats(events: events, now: now, calendar: calendar)
        #expect(stats.bytesReclaimed == 0)
        #expect(stats.itemsRemoved == 0)
        #expect(stats.weeks.last?.bytesByModule[.cleanup] == 0)
    }

    @Test func removalTimeSavedIsCapped() {
        let big = ActivityEvent(kind: .removal, module: .cleanup, title: "", bytes: 1, items: 1_000_000)
        #expect(TimeSavedModel.estimate(big) == TimeSavedModel.maxPerRemoval)
    }
}

@Suite("InboxStore")
struct InboxStoreTests {
    @Test func postsNewestFirstAndCaps() async throws {
        let fixture = try FixtureBuilder()
        defer { try? fixture.remove() }
        let store = InboxStore(fileURL: fixture.url("inbox.json"), capacity: 3)
        let base = date("2026-10-01T00:00:00Z")
        for index in 0..<5 {
            await store.post(InboxMessage(date: base.addingTimeInterval(Double(index)), title: "m\(index)", body: ""))
        }
        #expect(await store.messages().map(\.title) == ["m4", "m3", "m2"])
    }

    @Test func markReadAndShareAcrossInstances() async throws {
        let fixture = try FixtureBuilder()
        defer { try? fixture.remove() }
        let url = fixture.url("support/inbox.json")
        let app = InboxStore(fileURL: url)
        let agent = InboxStore(fileURL: url)
        let first = InboxMessage(date: date("2026-10-01T00:00:00Z"), kind: .scanResult, title: "Scheduled scan", body: "2 GB",
                                 link: "maccleaner://smart-care")
        await agent.post(first)
        await app.post(InboxMessage(date: date("2026-10-02T00:00:00Z"), title: "Second", body: ""))
        #expect(await agent.messages().map(\.title) == ["Second", "Scheduled scan"])

        await app.markRead(first.id)
        #expect(await agent.messages().filter(\.isRead).map(\.id) == [first.id])
        await agent.markRead(nil)
        #expect(await app.messages().allSatisfy(\.isRead))
        #expect(await app.messages().last?.link == "maccleaner://smart-care")

        await agent.removeAll()
        #expect(await app.messages().isEmpty)
    }

    @Test func corruptFileReadsAsEmpty() async throws {
        let fixture = try FixtureBuilder()
        defer { try? fixture.remove() }
        let url = fixture.url("inbox.json")
        try Data("not json".utf8).write(to: url)
        let store = InboxStore(fileURL: url)
        #expect(await store.messages().isEmpty)
        await store.post(InboxMessage(title: "fresh", body: ""))
        #expect(await store.messages().map(\.title) == ["fresh"])
    }

    @Test func recordRoundTripsDictionaries() throws {
        let fixture = try FixtureBuilder()
        defer { try? fixture.remove() }
        let record = JSONFileRecord<[UUID: Date]>(fileURL: fixture.url("nested/runs.json"))
        #expect(record.load() == nil)
        let value = [UUID(): date("2026-10-01T00:00:00Z")]
        try record.save(value)
        #expect(record.load() == value)
    }
}
