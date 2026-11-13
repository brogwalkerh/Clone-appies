import Foundation
import Testing
import CleanerCore
@testable import SmartCareModule

private let now = date("2026-10-29T12:00:00Z")
private let day: TimeInterval = 86_400

private func ids(_ snapshot: AssistantSnapshot, limit: Int = 20) -> [String] {
    Assistant().recommendations(for: snapshot, limit: limit).map(\.id)
}

/// A snapshot of a well-kept Mac: no rule should fire.
private func healthy() -> AssistantSnapshot {
    var s = AssistantSnapshot(now: now)
    s.lastScan = [.cleanup: now.addingTimeInterval(-day), .protection: now.addingTimeInterval(-day)]
    s.summaries = [.cleanup: ScanSummary(totalFindings: 1, totalBytes: 10_000_000, byCategory: [:], duration: 1)]
    s.lastSmartCare = now.addingTimeInterval(-day)
    s.lastMaintenance = now.addingTimeInterval(-2 * day)
    s.trashBytes = 5_000_000
    s.diskFreeBytes = 400_000_000_000
    s.diskCapacityBytes = 1_000_000_000_000
    s.hasFullDiskAccess = true
    s.helperInstalled = true
    s.updatesAvailable = 0
    s.signaturesUpdated = now.addingTimeInterval(-day)
    s.hasEnabledSchedule = true
    return s
}

@Suite("Assistant")
struct AssistantTests {
    @Test func healthyMacHasNoRecommendations() {
        #expect(ids(healthy()).isEmpty)
    }

    @Test func freshInstallSuggestsFirstScanOnly() {
        // Nothing known yet: only the first-scan rule may fire, never guesses from nil facts.
        #expect(ids(AssistantSnapshot(now: now)) == ["firstScan"])
    }

    @Test(arguments: ["fullDiskAccess", "threats", "lowDisk", "junk", "trash", "staleScan",
                      "updates", "signatures", "helper", "maintenance", "schedule"])
    func eachRuleFiresAlone(rule: String) {
        var s = healthy()
        switch rule {
        case "fullDiskAccess": s.hasFullDiskAccess = false
        case "threats": s.openThreats = 2
        case "lowDisk": s.diskFreeBytes = 19_000_000_000
        case "junk": s.summaries[.cleanup] = ScanSummary(totalFindings: 9, totalBytes: 800_000_000, byCategory: [:], duration: 1)
        case "trash": s.trashBytes = 2_000_000_000
        case "staleScan":
            s.lastScan = [.protection: now.addingTimeInterval(-20 * day)]
            s.lastSmartCare = now.addingTimeInterval(-20 * day)
        case "updates": s.updatesAvailable = 3
        case "signatures": s.signaturesUpdated = now.addingTimeInterval(-8 * day)
        case "helper": s.helperInstalled = false
        case "maintenance": s.lastMaintenance = nil
        case "schedule": s.hasEnabledSchedule = false
        default: Issue.record("no change defined for \(rule)")
        }
        #expect(ids(s) == [rule])
    }

    @Test func lowDiskUsesTenPercentOnLargeDisks() {
        var s = healthy()
        s.diskCapacityBytes = 4_000_000_000_000
        s.diskFreeBytes = 390_000_000_000          // under 10% of 4 TB, over 20 GB
        #expect(ids(s) == ["lowDisk"])
    }

    @Test func junkIsQuietAfterARemovalFollowsTheScan() {
        var s = healthy()
        s.summaries[.cleanup] = ScanSummary(totalFindings: 9, totalBytes: 800_000_000, byCategory: [:], duration: 1)
        s.lastRemoval = now
        #expect(ids(s).isEmpty)
    }

    @Test func orderedByPriorityAndLimited() {
        var s = healthy()
        s.hasFullDiskAccess = false
        s.helperInstalled = false
        s.openThreats = 1
        s.trashBytes = 3_000_000_000
        let all = Assistant().recommendations(for: s, limit: 10)
        #expect(all.map(\.id) == ["fullDiskAccess", "threats", "trash", "helper"])
        #expect(all[1].title == "Review 1 threat")
        #expect(all.map(\.priority) == all.map(\.priority).sorted(by: >))
        #expect(Assistant().recommendations(for: s, limit: 2).map(\.id) == ["fullDiskAccess", "threats"])
    }

    @Test func dismissalSuppressesForAPeriod() {
        var s = healthy()
        s.helperInstalled = false
        let assistant = Assistant()
        #expect(assistant.recommendations(for: s, dismissed: ["helper": now.addingTimeInterval(-day)]).isEmpty)
        #expect(assistant.recommendations(for: s, dismissed: ["helper": now.addingTimeInterval(-8 * day)]).map(\.id) == ["helper"])
    }

    @Test func customRulesKeepTheirOrderOnTies() {
        let a = ClosureRule(id: "a") { _ in AssistantRecommendation(id: "a", priority: 1, symbol: "", title: "", detail: "", action: .runSmartCare) }
        let b = ClosureRule(id: "b") { _ in AssistantRecommendation(id: "b", priority: 1, symbol: "", title: "", detail: "", action: .runSmartCare) }
        #expect(Assistant(rules: [b, a]).recommendations(for: AssistantSnapshot(now: now)).map(\.id) == ["b", "a"])
    }
}

@Suite("ScanSchedule")
struct ScheduleTests {
    private let calendar = utcCalendar()

    @Test func dailyWeeklyMonthlyNextFire() {
        let from = date("2026-10-29T12:00:00Z")   // Thursday
        let daily = ScanSchedule(cadence: .daily, hour: 9, minute: 30, target: .smartCareScan)
        #expect(daily.nextFire(after: from, calendar: calendar) == date("2026-10-30T09:30:00Z"))
        let dailyLater = ScanSchedule(cadence: .daily, hour: 18, minute: 0, target: .smartCareScan)
        #expect(dailyLater.nextFire(after: from, calendar: calendar) == date("2026-10-29T18:00:00Z"))
        let weekly = ScanSchedule(cadence: .weekly(weekday: 2), hour: 8, minute: 0, target: .moduleScan(.cleanup))
        #expect(weekly.nextFire(after: from, calendar: calendar) == date("2026-11-02T08:00:00Z"))   // Monday
        let monthly = ScanSchedule(cadence: .monthly(day: 1), hour: 7, minute: 15, target: .smartCareScan)
        #expect(monthly.nextFire(after: from, calendar: calendar) == date("2026-11-01T07:15:00Z"))
    }

    @Test func invalidCadenceNeverFires() {
        #expect(ScanSchedule(cadence: .weekly(weekday: 9), hour: 1, minute: 0, target: .smartCareScan)
            .nextFire(after: .now, calendar: calendar) == nil)
        #expect(ScanSchedule(cadence: .monthly(day: 31), hour: 1, minute: 0, target: .smartCareScan)
            .nextFire(after: .now, calendar: calendar) == nil)
    }

    @Test func hourAndMinuteAreClamped() {
        let s = ScanSchedule(cadence: .daily, hour: 30, minute: -5, target: .smartCareScan)
        #expect(s.hour == 23)
        #expect(s.minute == 0)
    }

    @Test func missedRunsCollapseIntoOne() {
        let created = date("2026-10-01T00:00:00Z")
        let daily = ScanSchedule(cadence: .daily, hour: 9, minute: 0, target: .smartCareScan, createdAt: created)
        let evaluator = ScheduleEvaluator(calendar: calendar)
        let now = date("2026-10-29T12:00:00Z")

        // Never ran, created weeks ago: due once.
        #expect(evaluator.due([daily], lastRuns: [:], now: now).map(\.id) == [daily.id])
        // Ran this morning after 09:00: not due until tomorrow.
        #expect(evaluator.due([daily], lastRuns: [daily.id: date("2026-10-29T09:00:05Z")], now: now).isEmpty)
        // Ran yesterday: today's 09:00 has passed.
        #expect(evaluator.due([daily], lastRuns: [daily.id: date("2026-10-28T09:00:05Z")], now: now).count == 1)
        // Created after today's 09:00: waits for tomorrow.
        let fresh = ScanSchedule(cadence: .daily, hour: 9, minute: 0, target: .smartCareScan, createdAt: date("2026-10-29T10:00:00Z"))
        #expect(evaluator.due([fresh], lastRuns: [:], now: now).isEmpty)
        // Disabled schedules never come due.
        var off = daily
        off.isEnabled = false
        #expect(evaluator.due([off], lastRuns: [:], now: now).isEmpty)
    }

    @Test func enablingDoesNotMakeUpForTheTimeItWasOff() {
        let evaluator = ScheduleEvaluator(calendar: calendar)
        let created = date("2026-10-01T00:00:00Z")
        let now = date("2026-10-29T12:00:00Z")
        let set = UUID()

        // Created disabled weeks ago, switched on just now: waits for the next 09:00.
        var schedule = ScanSchedule(isEnabled: false, cadence: .daily, hour: 9, minute: 0,
                                    target: .actionSet(set), createdAt: created)
        #expect(schedule.enabledAt == nil)
        schedule.setEnabled(true, at: now)
        #expect(schedule.enabledAt == now)
        #expect(evaluator.due([schedule], lastRuns: [:], now: now.addingTimeInterval(60)).isEmpty)
        #expect(evaluator.nextFire([schedule], lastRuns: [:], now: now) == date("2026-10-30T09:00:00Z"))
        #expect(evaluator.due([schedule], lastRuns: [:], now: date("2026-10-30T09:00:30Z")).map(\.id) == [schedule.id])

        // Ran weeks ago, then off, re-enabled now: same.
        var paused = ScanSchedule(cadence: .daily, hour: 9, minute: 0, target: .actionSet(set), createdAt: created)
        #expect(paused.enabledAt == created)
        let lastRuns = [paused.id: date("2026-10-05T09:00:05Z")]
        paused.setEnabled(false, at: date("2026-10-06T00:00:00Z"))
        #expect(evaluator.due([paused], lastRuns: lastRuns, now: now).isEmpty)
        paused.setEnabled(true, at: now)
        #expect(evaluator.due([paused], lastRuns: lastRuns, now: now.addingTimeInterval(60)).isEmpty)
        #expect(evaluator.due([paused], lastRuns: lastRuns, now: date("2026-10-30T09:00:30Z")).count == 1)
        // A run after re-enabling still wins over enabledAt.
        #expect(evaluator.due([paused], lastRuns: [paused.id: date("2026-10-30T09:00:10Z")],
                              now: date("2026-10-30T12:00:00Z")).isEmpty)

        // Setting an enabled schedule to enabled again keeps its anchor.
        paused.setEnabled(true, at: date("2026-11-05T00:00:00Z"))
        #expect(paused.enabledAt == now)
    }

    /// The app's toggle assigns the property on a copy and saves it.
    @Test func assigningIsEnabledStampsEnabledAt() {
        let evaluator = ScheduleEvaluator(calendar: calendar)
        var schedule = ScanSchedule(isEnabled: false, cadence: .daily, hour: 9, minute: 0, target: .smartCareScan,
                                    createdAt: date("2020-01-01T00:00:00Z"))
        let before = Date()
        schedule.isEnabled = true
        let stamped = schedule.enabledAt
        #expect(stamped != nil)
        #expect((stamped ?? .distantPast) >= before)
        #expect(evaluator.due([schedule], lastRuns: [:], now: Date()).isEmpty)
        // Re-assigning true, or switching off, leaves the stamp alone.
        schedule.isEnabled = true
        #expect(schedule.enabledAt == stamped)
        schedule.isEnabled = false
        #expect(schedule.enabledAt == stamped)
    }

    @Test func decodingClampsAndAcceptsFilesWithoutEnabledAt() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // As written before `enabledAt` existed, then hand-edited to hour 24.
        let original = ScanSchedule(cadence: .daily, hour: 9, minute: 0, target: .smartCareScan,
                                    createdAt: date("2026-10-01T00:00:00Z"))
        var object = try #require(try JSONSerialization.jsonObject(with: encoder.encode(original)) as? [String: Any])
        #expect(object["enabledAt"] != nil)
        object["enabledAt"] = nil
        object["hour"] = 24
        object["minute"] = 75
        let legacy = try decoder.decode(ScanSchedule.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.hour == 23)
        #expect(legacy.minute == 59)
        #expect(legacy.enabledAt == nil)
        #expect(legacy.isEnabled)
        // It fires (at 23:59) and, never having been toggled, counts from its creation.
        let evaluator = ScheduleEvaluator(calendar: calendar)
        #expect(legacy.nextFire(after: date("2026-10-29T12:00:00Z"), calendar: calendar) == date("2026-10-29T23:59:00Z"))
        #expect(evaluator.due([legacy], lastRuns: [:], now: date("2026-10-29T12:00:00Z")).count == 1)
        object["hour"] = -3
        #expect(try decoder.decode(ScanSchedule.self, from: JSONSerialization.data(withJSONObject: object)).hour == 0)
        // enabledAt round-trips.
        var toggled = original
        toggled.setEnabled(false)
        toggled.setEnabled(true, at: date("2026-10-20T00:00:00Z"))
        #expect(try decoder.decode(ScanSchedule.self, from: encoder.encode(toggled)) == toggled)
    }

    @Test func nextFireAcrossSchedules() {
        let evaluator = ScheduleEvaluator(calendar: calendar)
        let now = date("2026-10-29T12:00:00Z")
        let created = date("2026-10-01T00:00:00Z")
        let a = ScanSchedule(cadence: .daily, hour: 9, minute: 0, target: .smartCareScan, createdAt: created)
        let b = ScanSchedule(cadence: .daily, hour: 20, minute: 0, target: .moduleScan(.clutter), createdAt: created)
        var c = ScanSchedule(cadence: .daily, hour: 13, minute: 0, target: .smartCareScan, createdAt: created)
        c.isEnabled = false
        #expect(evaluator.nextFire([a, b, c], lastRuns: [:], now: now) == date("2026-10-29T20:00:00Z"))
        #expect(evaluator.nextFire([], lastRuns: [:], now: now) == nil)
    }

    @Test func springForwardGapResolvesToTheNextValidTime() {
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        // 2027-03-14: clocks jump from 02:00 to 03:00 in Los Angeles.
        let s = ScanSchedule(cadence: .daily, hour: 2, minute: 30, target: .smartCareScan)
        let next = s.nextFire(after: date("2027-03-14T08:00:00Z"), calendar: pacific)   // 00:00 PST
        #expect(next == date("2027-03-14T10:00:00Z"))   // 03:00 PDT
    }

    @Test func codableRoundTrip() throws {
        let schedules = [
            ScanSchedule(cadence: .weekly(weekday: 6), hour: 17, minute: 45, target: .actionSet(UUID())),
            ScanSchedule(isEnabled: false, cadence: .monthly(day: 28), hour: 3, minute: 0, target: .moduleScan(.protection)),
        ]
        let data = try JSONEncoder().encode(schedules)
        #expect(try JSONDecoder().decode([ScanSchedule].self, from: data) == schedules)
    }
}
