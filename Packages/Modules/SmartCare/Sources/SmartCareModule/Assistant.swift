import Foundation
import CleanerCore

/// Facts the Assistant's rules look at (PLAN.md §3.1). The app fills it from
/// its state and the activity log; anything unknown stays nil, and rules that
/// need an unknown fact stay quiet rather than guess.
public struct AssistantSnapshot: Sendable, Hashable {
    public var now: Date
    public var lastScan: [ModuleID: Date] = [:]
    public var summaries: [ModuleID: ScanSummary] = [:]
    public var lastSmartCare: Date?
    public var lastRemoval: Date?
    public var lastMaintenance: Date?
    public var trashBytes: Int64?
    public var diskFreeBytes: Int64?
    public var diskCapacityBytes: Int64?
    public var hasFullDiskAccess: Bool?
    public var helperInstalled: Bool?
    public var updatesAvailable: Int?
    public var openThreats: Int = 0
    public var signaturesUpdated: Date?
    public var hasEnabledSchedule = false

    public init(now: Date = .now) {
        self.now = now
    }

    /// The most recent scan of any module, or Smart Care run.
    public var lastAnyScan: Date? {
        (Array(lastScan.values) + [lastSmartCare].compactMap { $0 }).max()
    }
}

public enum AssistantDestination: String, Codable, Sendable, Hashable {
    case smartCare, cleanup, protection, performance, applications, clutter, spaceLens, myActivity, scheduler
}

public enum AssistantAction: Codable, Sendable, Hashable {
    case open(AssistantDestination)
    case grantFullDiskAccess
    case installHelper
    case runSmartCare
    case updateSignatures
}

public struct AssistantRecommendation: Sendable, Hashable, Identifiable {
    /// The rule id: stable, used to remember dismissals.
    public let id: String
    /// Higher shows first.
    public let priority: Int
    /// SF Symbol name.
    public let symbol: String
    public let title: String
    public let detail: String
    public let action: AssistantAction

    public init(id: String, priority: Int, symbol: String, title: String, detail: String, action: AssistantAction) {
        self.id = id
        self.priority = priority
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.action = action
    }
}

public protocol AssistantRule: Sendable {
    var id: String { get }
    func evaluate(_ snapshot: AssistantSnapshot) -> AssistantRecommendation?
}

/// A rule defined by a closure, so the built-in table reads as data.
public struct ClosureRule: AssistantRule {
    public let id: String
    private let body: @Sendable (AssistantSnapshot) -> AssistantRecommendation?

    public init(id: String, _ body: @escaping @Sendable (AssistantSnapshot) -> AssistantRecommendation?) {
        self.id = id
        self.body = body
    }

    public func evaluate(_ snapshot: AssistantSnapshot) -> AssistantRecommendation? {
        body(snapshot)
    }
}

public struct Assistant: Sendable {
    private let rules: [any AssistantRule]

    public init(rules: [any AssistantRule] = Assistant.defaultRules) {
        self.rules = rules
    }

    /// Sorted by priority, ties in rule order. A rule dismissed less than
    /// `dismissalPeriod` ago is skipped.
    public func recommendations(for snapshot: AssistantSnapshot, dismissed: [String: Date] = [:],
                                dismissalPeriod: TimeInterval = 7 * 86_400,
                                limit: Int = 5) -> [AssistantRecommendation] {
        let fired = rules.enumerated().compactMap { index, rule -> (Int, AssistantRecommendation)? in
            if let at = dismissed[rule.id], snapshot.now.timeIntervalSince(at) < dismissalPeriod { return nil }
            return rule.evaluate(snapshot).map { (index, $0) }
        }
        return fired
            .sorted { $0.1.priority != $1.1.priority ? $0.1.priority > $1.1.priority : $0.0 < $1.0 }
            .prefix(max(limit, 0))
            .map(\.1)
    }
}

// MARK: - Built-in rules

extension Assistant {
    static let day: TimeInterval = 86_400

    /// Thresholds are documented next to each rule; tests pin them.
    public static let defaultRules: [any AssistantRule] = [
        ClosureRule(id: "fullDiskAccess") { s in
            guard s.hasFullDiskAccess == false else { return nil }
            return AssistantRecommendation(
                id: "fullDiskAccess", priority: 100, symbol: "lock.shield",
                title: "Grant Full Disk Access",
                detail: "Scans can only see part of your Mac until Full Disk Access is on.",
                action: .grantFullDiskAccess)
        },
        ClosureRule(id: "threats") { s in
            guard s.openThreats > 0 else { return nil }
            return AssistantRecommendation(
                id: "threats", priority: 95, symbol: "exclamationmark.shield",
                title: s.openThreats == 1 ? "Review 1 threat" : "Review \(s.openThreats) threats",
                detail: "The last malware scan found items you can quarantine.",
                action: .open(.protection))
        },
        // Under 10% or 20 GB free, whichever is larger.
        ClosureRule(id: "lowDisk") { s in
            guard let free = s.diskFreeBytes, let capacity = s.diskCapacityBytes, capacity > 0 else { return nil }
            let threshold = max(capacity / 10, 20_000_000_000)
            guard free < threshold else { return nil }
            return AssistantRecommendation(
                id: "lowDisk", priority: 90, symbol: "internaldrive",
                title: "Your disk is almost full",
                detail: "\(ByteFormatter.string(free)) free. Space Lens shows what takes up the rest.",
                action: .open(.spaceLens))
        },
        // Cleanup found at least 500 MB and nothing was removed since.
        ClosureRule(id: "junk") { s in
            guard let summary = s.summaries[.cleanup], summary.totalBytes >= 500_000_000 else { return nil }
            if let scanned = s.lastScan[.cleanup], let removed = s.lastRemoval, removed >= scanned { return nil }
            return AssistantRecommendation(
                id: "junk", priority: 80, symbol: "trash",
                title: "Review \(ByteFormatter.string(summary.totalBytes)) of junk",
                detail: "Cleanup found files you can safely remove.",
                action: .open(.cleanup))
        },
        // Trash over 1 GB.
        ClosureRule(id: "trash") { s in
            guard let bytes = s.trashBytes, bytes >= 1_000_000_000 else { return nil }
            return AssistantRecommendation(
                id: "trash", priority: 70, symbol: "trash.circle",
                title: "Empty \(ByteFormatter.string(bytes)) from the Trash",
                detail: "Items in the Trash still take up disk space.",
                action: .open(.cleanup))
        },
        ClosureRule(id: "firstScan") { s in
            guard s.lastAnyScan == nil else { return nil }
            return AssistantRecommendation(
                id: "firstScan", priority: 60, symbol: "sparkles",
                title: "Run your first Smart Care scan",
                detail: "One scan checks for junk, threats, slowdowns, outdated apps and clutter.",
                action: .runSmartCare)
        },
        // No scan of any kind for 14 days.
        ClosureRule(id: "staleScan") { s in
            guard let last = s.lastAnyScan, s.now.timeIntervalSince(last) >= 14 * day else { return nil }
            let days = Int(s.now.timeIntervalSince(last) / day)
            return AssistantRecommendation(
                id: "staleScan", priority: 50, symbol: "clock.arrow.circlepath",
                title: "It has been \(days) days since your last scan",
                detail: "Caches and logs build up again over a couple of weeks.",
                action: .runSmartCare)
        },
        ClosureRule(id: "updates") { s in
            guard let count = s.updatesAvailable, count > 0 else { return nil }
            return AssistantRecommendation(
                id: "updates", priority: 45, symbol: "arrow.up.circle",
                title: count == 1 ? "1 app update is available" : "\(count) app updates are available",
                detail: "Updates fix bugs and security issues.",
                action: .open(.applications))
        },
        // Signatures older than 7 days (or never updated) once Protection has been used.
        ClosureRule(id: "signatures") { s in
            guard s.lastScan[.protection] != nil else { return nil }
            if let updated = s.signaturesUpdated, s.now.timeIntervalSince(updated) < 7 * day { return nil }
            return AssistantRecommendation(
                id: "signatures", priority: 40, symbol: "shield.lefthalf.filled",
                title: "Update malware signatures",
                detail: "New signatures help Protection recognise recent threats.",
                action: .updateSignatures)
        },
        ClosureRule(id: "helper") { s in
            guard s.helperInstalled == false else { return nil }
            return AssistantRecommendation(
                id: "helper", priority: 30, symbol: "wrench.and.screwdriver",
                title: "Install the helper for maintenance tasks",
                detail: "Flushing DNS, running periodic scripts and thinning snapshots need it.",
                action: .installHelper)
        },
        // No maintenance for 30 days, once the app has been in use for a while.
        ClosureRule(id: "maintenance") { s in
            guard s.lastAnyScan != nil else { return nil }
            if let last = s.lastMaintenance, s.now.timeIntervalSince(last) < 30 * day { return nil }
            return AssistantRecommendation(
                id: "maintenance", priority: 20, symbol: "gauge.with.dots.needle.67percent",
                title: "Run maintenance tasks",
                detail: "Freeing RAM and flushing the DNS cache keep things responsive.",
                action: .open(.performance))
        },
        ClosureRule(id: "schedule") { s in
            guard !s.hasEnabledSchedule, s.lastSmartCare != nil else { return nil }
            return AssistantRecommendation(
                id: "schedule", priority: 10, symbol: "calendar.badge.clock",
                title: "Schedule regular scans",
                detail: "A weekly Smart Care scan tells you when there is something to clean.",
                action: .open(.scheduler))
        },
    ]
}
