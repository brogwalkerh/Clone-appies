import Foundation
import Observation
import CleanerCore
import CleanupModule
import ClutterModule
import ApplicationsModule
import PerformanceModule
import ProtectionModule
import SmartCareModule

/// My Tools action sets and Settings › Scheduler (PLAN.md §3.12), stored in
/// the shared SmartCareStorage files so the CLI and the menu bar agent see
/// the same sets and schedules (ADR 0007).
@MainActor
@Observable
final class AutomationState {
    /// Presets (unless the user saved an edited copy) followed by the user's own sets.
    private(set) var actionSets: [ActionSet] = []
    private(set) var schedules: [ScanSchedule] = []
    private(set) var runningSetID: UUID?
    /// Per-step lines of the current or last action set run.
    private(set) var stepLines: [String] = []
    private(set) var lastReport: ActionSetReport?
    var lastError: String?

    @ObservationIgnored let storage: SmartCareStorage
    @ObservationIgnored private var savedSets: [ActionSet] = []

    init(storage: SmartCareStorage = ActivityCenter.shared.storage) {
        self.storage = storage
        reload()
    }

    var isRunning: Bool { runningSetID != nil }

    func reload() {
        savedSets = storage.actionSets.load() ?? []
        let savedIDs = Set(savedSets.map(\.id))
        actionSets = ActionSetPresets.all.filter { !savedIDs.contains($0.id) } + savedSets
        schedules = storage.schedules.load() ?? []
    }

    /// True for the user's own sets and for presets they edited.
    func isSaved(_ set: ActionSet) -> Bool {
        savedSets.contains { $0.id == set.id }
    }

    func isPreset(_ set: ActionSet) -> Bool {
        ActionSetPresets.all.contains { $0.id == set.id }
    }

    func actionSet(withID id: UUID) -> ActionSet? {
        actionSets.first { $0.id == id }
    }

    // MARK: Editing

    /// Every scanner an action set step may name, in display order.
    nonisolated static func allScanners() -> [any CleanerScanner] {
        CleanupScanners.all() + ApplicationsScanners.all() + PerformanceScanners.all()
            + PrivacyScanners.all() + ClutterScanners.all(imageFeatures: nil)
    }

    func problems(in set: ActionSet) -> [String] {
        set.validate(knownScannerIDs: Set(Self.allScanners().map { type(of: $0).id }),
                     knownTaskIDs: Set(MaintenanceCatalog.all.map(\.id)))
    }

    /// Inserts or replaces `set` among the saved sets. Editing a preset saves a copy with its id.
    func save(_ set: ActionSet) {
        if let index = savedSets.firstIndex(where: { $0.id == set.id }) {
            savedSets[index] = set
        } else {
            savedSets.append(set)
        }
        persistSets()
    }

    /// Deletes a user set, or reverts an edited preset to the built-in one.
    func delete(_ set: ActionSet) {
        savedSets.removeAll { $0.id == set.id }
        persistSets()
        // A schedule for a deleted set would fail every time; drop it with the set.
        if !isPreset(set) {
            saveSchedules(schedules.filter { $0.target != .actionSet(set.id) })
        }
    }

    private func persistSets() {
        do {
            try storage.actionSets.save(savedSets)
        } catch {
            lastError = "Could not save action sets: \(error.localizedDescription)"
        }
        reload()
    }

    func saveSchedules(_ updated: [ScanSchedule]) {
        do {
            try storage.schedules.save(updated)
            schedules = updated
        } catch {
            lastError = "Could not save schedules: \(error.localizedDescription)"
        }
    }

    // MARK: Running

    /// Runs `set` with the app's remover (Trash first, protected paths enforced)
    /// and maintenance runner, records activity, and returns the report.
    @discardableResult
    func run(_ set: ActionSet) async -> ActionSetReport? {
        guard runningSetID == nil else { return nil }
        runningSetID = set.id
        stepLines = []
        lastError = nil
        defer { runningSetID = nil }

        let runner = ActionSetRunner(scanners: Self.allScanners(),
                                     remover: FindingsActions.makeRemover(),
                                     maintenance: MaintenanceState.makeRunner(),
                                     removalMode: SettingsStore.removalMode())
        var report: ActionSetReport?
        for await event in runner.run(set, context: SettingsStore.scanContext()) {
            switch event {
            case .stepStarted:
                break
            case .stepFinished(let result):
                stepLines.append("\(result.succeeded ? "✓" : "✗") \(result.message)")
            case .completed(let finished):
                report = finished
            }
        }
        guard let report else { return nil }
        lastReport = report

        var events: [ActivityEvent] = []
        for result in report.results {
            if let manifest = result.manifest { events += ActivityEvent.removals(manifest) }
            if let maintenance = result.maintenance { events.append(.maintenance(maintenance)) }
        }
        events.append(ActivityEvent(kind: .actionSet, module: nil, title: "Ran \(set.name)",
                                    bytes: report.bytesReclaimed, items: report.results.count,
                                    reference: set.id.uuidString))
        ActivityCenter.shared.record(events)
        return report
    }

    /// Schedule id -> last run, for the Scheduler's "Last run" column.
    func lastRuns() -> [UUID: Date] {
        storage.scheduleRuns.load() ?? [:]
    }
}
