import Foundation
import CleanerCore
import PerformanceModule

// MARK: - Events

public enum ActivityKind: String, Codable, Sendable {
    case scan, removal, undo, quarantine, maintenance, actionSet
}

/// One line of My Activity history (PLAN.md §3.12). `bytes` is what the event
/// freed (or, for `.undo`, put back); scans record what they found.
public struct ActivityEvent: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let date: Date
    public let kind: ActivityKind
    public let module: ModuleID?
    public let title: String
    public let bytes: Int64
    public let items: Int
    /// Manifest id, maintenance task id or action set id.
    public let reference: String?

    public init(id: UUID = UUID(), date: Date = .now, kind: ActivityKind, module: ModuleID?, title: String,
                bytes: Int64 = 0, items: Int = 0, reference: String? = nil) {
        self.id = id
        self.date = date
        self.kind = kind
        self.module = module
        self.title = title
        self.bytes = bytes
        self.items = items
        self.reference = reference
    }

    public static func scan(_ summary: ScanSummary, module: ModuleID, date: Date = .now) -> ActivityEvent {
        ActivityEvent(date: date, kind: .scan, module: module,
                      title: "Scanned \(module.displayName)",
                      bytes: summary.totalBytes, items: summary.totalFindings)
    }

    public static func removal(_ manifest: RemovalManifest, module: ModuleID) -> ActivityEvent {
        let removed = manifest.records.lazy.filter(\.succeeded).count
        return ActivityEvent(date: manifest.startedAt, kind: .removal, module: module,
                             title: "Cleaned \(module.displayName)",
                             bytes: manifest.bytesReclaimed, items: removed,
                             reference: manifest.id.uuidString)
    }

    /// One `.removal` event per module of the removed findings, for runs that
    /// span modules (Smart Care, action sets). Modules with no successful
    /// removal are left out.
    public static func removals(_ manifest: RemovalManifest) -> [ActivityEvent] {
        let succeeded = manifest.records.filter(\.succeeded)
        let modules = ModuleID.allCases.filter { module in succeeded.contains { $0.finding.category.module == module } }
        return modules.map { module in
            let records = succeeded.filter { $0.finding.category.module == module }
            return ActivityEvent(date: manifest.startedAt, kind: .removal, module: module,
                                 title: "Cleaned \(module.displayName)",
                                 bytes: records.reduce(0) { $0 + $1.finding.sizeBytes },
                                 items: records.count, reference: manifest.id.uuidString)
        }
    }

    public static func undo(_ restored: [RemovalRecord], module: ModuleID, date: Date = .now) -> ActivityEvent {
        let succeeded = restored.filter(\.succeeded)
        return ActivityEvent(date: date, kind: .undo, module: module,
                             title: "Restored items from the Trash",
                             bytes: succeeded.reduce(0) { $0 + $1.finding.sizeBytes },
                             items: succeeded.count)
    }

    public static func quarantine(threats: Int, bytes: Int64, date: Date = .now) -> ActivityEvent {
        ActivityEvent(date: date, kind: .quarantine, module: .protection,
                      title: threats == 1 ? "Quarantined 1 threat" : "Quarantined \(threats) threats",
                      bytes: bytes, items: threats)
    }

    public static func maintenance(_ result: MaintenanceResult, date: Date = .now) -> ActivityEvent {
        let name = MaintenanceCatalog.task(id: result.taskID)?.name ?? result.taskID
        return ActivityEvent(date: date, kind: .maintenance, module: .performance,
                             title: result.succeeded ? name : "\(name) (failed)",
                             bytes: result.succeeded ? max(result.bytesReclaimed ?? 0, 0) : 0,
                             items: result.succeeded ? 1 : 0,
                             reference: result.taskID)
    }
}

extension ModuleID {
    /// Title used in activity lines and CLI output.
    public var displayName: String {
        switch self {
        case .cleanup: return "Cleanup"
        case .protection: return "Protection"
        case .performance: return "Performance"
        case .applications: return "Applications"
        case .clutter: return "My Clutter"
        }
    }
}

// MARK: - Stores

public protocol ActivityStore: Sendable {
    func append(_ events: [ActivityEvent]) async throws
    /// Events on or after `since` (all when nil), oldest first.
    func events(since: Date?) async throws -> [ActivityEvent]
    func removeAll() async throws
}

/// Append-only JSON Lines log (ADR 0007). Lines that fail to decode are
/// skipped, so a torn write costs one event. On first use the file is
/// compacted to the newest `maxEvents`.
public actor JSONLinesActivityStore: ActivityStore {
    private let fileURL: URL
    private let maxEvents: Int
    private var compacted = false

    public init(fileURL: URL, maxEvents: Int = 5_000) {
        self.fileURL = fileURL
        self.maxEvents = max(1, maxEvents)
    }

    public func append(_ events: [ActivityEvent]) async throws {
        guard !events.isEmpty else { return }
        try compactIfNeeded()
        let encoder = Self.encoder()
        var data = Data()
        for event in events {
            data.append(try encoder.encode(event))
            data.append(0x0A)
        }
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            return
        }
        let handle = try FileHandle(forUpdating: fileURL)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        if end > 0 {
            // After a torn write the last line has no newline; start a fresh
            // line so only the torn event is lost, not this one too.
            try handle.seek(toOffset: end - 1)
            if handle.readData(ofLength: 1) != Data([0x0A]) {
                data.insert(0x0A, at: 0)
            }
            try handle.seekToEnd()
        }
        try handle.write(contentsOf: data)
    }

    public func events(since: Date?) async throws -> [ActivityEvent] {
        try compactIfNeeded()
        let all = readAll()
        guard let since else { return all }
        return all.filter { $0.date >= since }
    }

    public func removeAll() async throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path) {
            try fm.removeItem(at: fileURL)
        }
    }

    private func readAll() -> [ActivityEvent] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = Self.decoder()
        var events: [ActivityEvent] = []
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if let event = try? decoder.decode(ActivityEvent.self, from: Data(line)) {
                events.append(event)
            }
        }
        // Appends from two processes can interleave out of order.
        return events.sorted { $0.date < $1.date }
    }

    private func compactIfNeeded() throws {
        guard !compacted else { return }
        compacted = true
        let all = readAll()
        guard all.count > maxEvents else { return }
        let encoder = Self.encoder()
        var data = Data()
        for event in all.suffix(maxEvents) {
            data.append(try encoder.encode(event))
            data.append(0x0A)
        }
        try data.write(to: fileURL, options: .atomic)
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// For previews, tests and the CLI's `--no-history`.
public actor InMemoryActivityStore: ActivityStore {
    private var stored: [ActivityEvent]

    public init(_ events: [ActivityEvent] = []) {
        stored = events.sorted { $0.date < $1.date }
    }

    public func append(_ events: [ActivityEvent]) async throws {
        stored.append(contentsOf: events)
        stored.sort { $0.date < $1.date }
    }

    public func events(since: Date?) async throws -> [ActivityEvent] {
        guard let since else { return stored }
        return stored.filter { $0.date >= since }
    }

    public func removeAll() async throws {
        stored.removeAll()
    }
}

// MARK: - Stats

/// "Time saved" is an estimate of the manual work each event replaced. The
/// constants are deliberately conservative and shown as "about" in the UI.
public enum TimeSavedModel {
    /// Finding and reviewing junk by hand.
    public static let perScan: TimeInterval = 120
    /// Locating and deleting one item by hand, capped per removal.
    public static let perRemovedItem: TimeInterval = 4
    public static let maxPerRemoval: TimeInterval = 1_800
    /// Looking up and running a maintenance command.
    public static let perMaintenanceTask: TimeInterval = 180
    /// Investigating one suspicious file.
    public static let perThreat: TimeInterval = 600

    public static func estimate(_ event: ActivityEvent) -> TimeInterval {
        switch event.kind {
        case .scan: return perScan
        case .removal: return min(Double(event.items) * perRemovedItem, maxPerRemoval)
        case .maintenance: return event.items > 0 ? perMaintenanceTask : 0
        case .quarantine: return Double(event.items) * perThreat
        case .undo, .actionSet: return 0
        }
    }
}

/// Aggregates for My Activity. Pure; computed from the whole event list.
public struct ActivityStats: Sendable, Hashable {
    public struct Week: Sendable, Hashable, Identifiable {
        public var id: Date { start }
        public let start: Date
        public let bytesByModule: [ModuleID: Int64]
        public var totalBytes: Int64 { bytesByModule.values.reduce(0, +) }
    }

    /// Removals and maintenance minus undos, all time; never negative.
    public let bytesReclaimed: Int64
    public let bytesReclaimedLast30Days: Int64
    public let itemsRemoved: Int
    public let threatsQuarantined: Int
    public let maintenanceRuns: Int
    public let estimatedTimeSaved: TimeInterval
    /// `weeks` buckets ending with the current week, oldest first.
    public let weeks: [Week]
    public let lastScan: [ModuleID: Date]
    public let lastRemoval: Date?
    public let lastMaintenance: Date?

    public init(events: [ActivityEvent], now: Date, calendar: Calendar = .current, weeks weekCount: Int = 8) {
        var reclaimed: Int64 = 0
        var recent: Int64 = 0
        var items = 0
        var threats = 0
        var maintenance = 0
        var saved: TimeInterval = 0
        var lastScan: [ModuleID: Date] = [:]
        var lastRemoval: Date?
        var lastMaintenance: Date?
        let monthAgo = now.addingTimeInterval(-30 * 86_400)

        let currentWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
        let starts: [Date] = (0..<max(weekCount, 0)).reversed().compactMap {
            calendar.date(byAdding: .weekOfYear, value: -$0, to: currentWeek)
        }
        var buckets: [Date: [ModuleID: Int64]] = [:]

        for event in events {
            saved += TimeSavedModel.estimate(event)
            let signed: Int64
            switch event.kind {
            case .removal:
                signed = event.bytes
                items += event.items
                lastRemoval = max(lastRemoval ?? event.date, event.date)
            case .maintenance:
                signed = event.bytes
                if event.items > 0 {
                    maintenance += 1
                    lastMaintenance = max(lastMaintenance ?? event.date, event.date)
                }
            case .undo:
                signed = -event.bytes
                items -= event.items
            case .quarantine:
                signed = 0
                threats += event.items
            case .scan:
                signed = 0
                if let module = event.module {
                    lastScan[module] = max(lastScan[module] ?? event.date, event.date)
                }
            case .actionSet:
                signed = 0
            }
            guard signed != 0 else { continue }
            reclaimed += signed
            if event.date >= monthAgo { recent += signed }
            if let module = event.module,
               let start = calendar.dateInterval(of: .weekOfYear, for: event.date)?.start,
               start >= (starts.first ?? .distantFuture), start <= currentWeek {
                buckets[start, default: [:]][module, default: 0] += signed
            }
        }

        bytesReclaimed = max(reclaimed, 0)
        bytesReclaimedLast30Days = max(recent, 0)
        itemsRemoved = max(items, 0)
        threatsQuarantined = threats
        maintenanceRuns = maintenance
        estimatedTimeSaved = saved
        self.weeks = starts.map { start in
            Week(start: start, bytesByModule: (buckets[start] ?? [:]).mapValues { max($0, 0) })
        }
        self.lastScan = lastScan
        self.lastRemoval = lastRemoval
        self.lastMaintenance = lastMaintenance
    }
}
