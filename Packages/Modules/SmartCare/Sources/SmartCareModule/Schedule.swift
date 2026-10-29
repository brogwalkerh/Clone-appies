import Foundation
import CleanerCore

public enum ScheduleCadence: Codable, Sendable, Hashable {
    case daily
    /// 1 = Sunday … 7 = Saturday (`Calendar` weekday numbering).
    case weekly(weekday: Int)
    /// 1…28, so every month has the day.
    case monthly(day: Int)
}

public enum ScheduleTarget: Codable, Sendable, Hashable {
    /// Scan every module and post a summary; never removes anything.
    case smartCareScan
    case moduleScan(ModuleID)
    /// Runs a My Tools action set, which may remove `.safe` findings.
    case actionSet(UUID)
}

/// One scheduled scan (Settings › Scheduler, PLAN.md §3.12).
public struct ScanSchedule: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public var isEnabled: Bool
    public var cadence: ScheduleCadence
    public var hour: Int
    public var minute: Int
    public var target: ScheduleTarget
    public let createdAt: Date

    public init(id: UUID = UUID(), isEnabled: Bool = true, cadence: ScheduleCadence, hour: Int, minute: Int,
                target: ScheduleTarget, createdAt: Date = .now) {
        self.id = id
        self.isEnabled = isEnabled
        self.cadence = cadence
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
        self.target = target
        self.createdAt = createdAt
    }

    /// The first occurrence strictly after `date`, or nil for an invalid cadence.
    public func nextFire(after date: Date, calendar: Calendar) -> Date? {
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        components.second = 0
        switch cadence {
        case .daily:
            break
        case .weekly(let weekday):
            guard (1...7).contains(weekday) else { return nil }
            components.weekday = weekday
        case .monthly(let day):
            guard (1...28).contains(day) else { return nil }
            components.day = day
        }
        // `.nextTime` resolves a DST gap (02:30 on spring-forward day) to the next valid time.
        return calendar.nextDate(after: date, matching: components, matchingPolicy: .nextTime,
                                 repeatedTimePolicy: .first, direction: .forward)
    }
}

/// Decides which schedules are due. Missed occurrences (the Mac was asleep or
/// off) collapse into a single run at the next check.
public struct ScheduleEvaluator: Sendable {
    public let calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// A schedule is due when an occurrence fell after its last run (or its
    /// creation, if it never ran) and at or before `now`.
    public func due(_ schedules: [ScanSchedule], lastRuns: [UUID: Date], now: Date) -> [ScanSchedule] {
        schedules.filter { schedule in
            guard schedule.isEnabled else { return false }
            let anchor = lastRuns[schedule.id] ?? schedule.createdAt
            guard let next = schedule.nextFire(after: anchor, calendar: calendar) else { return false }
            return next <= now
        }
    }

    /// The earliest upcoming occurrence across enabled schedules, for arming a timer.
    public func nextFire(_ schedules: [ScanSchedule], lastRuns: [UUID: Date], now: Date) -> Date? {
        schedules.compactMap { schedule -> Date? in
            guard schedule.isEnabled else { return nil }
            let anchor = max(lastRuns[schedule.id] ?? schedule.createdAt, now)
            return schedule.nextFire(after: anchor, calendar: calendar)
        }.min()
    }
}
