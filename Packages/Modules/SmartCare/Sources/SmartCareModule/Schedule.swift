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
    /// Turning a schedule on stamps `enabledAt`, so occurrences that fell
    /// while it was off are not made up for (see `ScheduleEvaluator.due`).
    public var isEnabled: Bool {
        didSet {
            if isEnabled, !oldValue { enabledAt = .now }
        }
    }
    public var cadence: ScheduleCadence
    public var hour: Int
    public var minute: Int
    public var target: ScheduleTarget
    public let createdAt: Date
    /// When the schedule was last switched on (its creation, if created
    /// enabled). Nil for a schedule that was never on, and for enabled
    /// schedules stored before this field existed (they count from `createdAt`).
    public private(set) var enabledAt: Date?

    public init(id: UUID = UUID(), isEnabled: Bool = true, cadence: ScheduleCadence, hour: Int, minute: Int,
                target: ScheduleTarget, createdAt: Date = .now) {
        self.id = id
        self.isEnabled = isEnabled
        self.cadence = cadence
        self.hour = Self.clampedHour(hour)
        self.minute = Self.clampedMinute(minute)
        self.target = target
        self.createdAt = createdAt
        self.enabledAt = isEnabled ? createdAt : nil
    }

    /// Hand-edited or foreign files get the same clamp as `init`; `enabledAt`
    /// is optional so files written before it existed still load.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        cadence = try container.decode(ScheduleCadence.self, forKey: .cadence)
        hour = Self.clampedHour(try container.decode(Int.self, forKey: .hour))
        minute = Self.clampedMinute(try container.decode(Int.self, forKey: .minute))
        target = try container.decode(ScheduleTarget.self, forKey: .target)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        enabledAt = try container.decodeIfPresent(Date.self, forKey: .enabledAt)
    }

    /// Same as assigning `isEnabled`, with an explicit clock. Switching on a
    /// schedule that is already on keeps its `enabledAt`.
    public mutating func setEnabled(_ enabled: Bool, at date: Date = .now) {
        let wasEnabled = isEnabled
        isEnabled = enabled
        if enabled, !wasEnabled { enabledAt = date }
    }

    /// Occurrences at or before this instant never fire: the later of the
    /// last run and the moment the schedule was created or last switched on.
    public func anchor(lastRun: Date?) -> Date {
        let since = max(enabledAt ?? createdAt, createdAt)
        guard let lastRun else { return since }
        return max(lastRun, since)
    }

    private static func clampedHour(_ hour: Int) -> Int { min(max(hour, 0), 23) }
    private static func clampedMinute(_ minute: Int) -> Int { min(max(minute, 0), 59) }

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

    /// A schedule is due when an occurrence fell at or before `now` and after
    /// both its last run and the moment it was created or last switched on. A
    /// schedule that was off for weeks therefore waits for its next occurrence
    /// instead of firing (for an action set: deleting) the moment it is enabled.
    public func due(_ schedules: [ScanSchedule], lastRuns: [UUID: Date], now: Date) -> [ScanSchedule] {
        schedules.filter { schedule in
            guard schedule.isEnabled else { return false }
            let anchor = schedule.anchor(lastRun: lastRuns[schedule.id])
            guard let next = schedule.nextFire(after: anchor, calendar: calendar) else { return false }
            return next <= now
        }
    }

    /// The earliest upcoming occurrence across enabled schedules, for arming a timer.
    public func nextFire(_ schedules: [ScanSchedule], lastRuns: [UUID: Date], now: Date) -> Date? {
        schedules.compactMap { schedule -> Date? in
            guard schedule.isEnabled else { return nil }
            let anchor = max(schedule.anchor(lastRun: lastRuns[schedule.id]), now)
            return schedule.nextFire(after: anchor, calendar: calendar)
        }.min()
    }
}
