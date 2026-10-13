import Foundation
import Observation
import CleanerCore
import HelperProtocol
import PerformanceModule

/// Selection and results for Performance › Maintenance (PLAN.md §3.4).
/// Lives on `AppState` so a run keeps streaming while the user navigates away.
/// Also used by `RunMaintenanceIntent` / `FreeUpRAMIntent` through `makeRunner()`.
@MainActor
@Observable
final class MaintenanceState {
    /// Task ids checked in the list. Starts with the safe, helper-free tasks.
    var selectedTaskIDs: Set<String>

    /// Result per task id for the current or last run.
    private(set) var results: [String: MaintenanceResult] = [:]

    /// Task ids of the current or last run in execution order.
    private(set) var runOrder: [String] = []

    /// Tasks of the current or last run that were not attempted (helper missing), with the reason.
    /// Kept apart from `results` because `MaintenanceResult` has no public init in the contract.
    private(set) var skipped: [String: String] = [:]

    private(set) var isRunning = false

    /// Set by `DeepLinkRouter` for `maccleaner://performance?task=…`; the
    /// Performance screen consumes it (switch to Maintenance, run or prompt for the helper).
    var pendingFocusTaskID: String?

    private var runTask: Task<Void, Never>?

    init() {
        selectedTaskIDs = Set(MaintenanceCatalog.all
            .filter { !$0.requiresHelper && $0.risk == .safe }
            .map(\.id))
    }

    // MARK: Derived

    var selectedTasks: [MaintenanceTask] {
        MaintenanceCatalog.all.filter { selectedTaskIDs.contains($0.id) }
    }

    /// The task the runner is on right now, assuming it executes `runOrder` sequentially.
    var runningTaskID: String? {
        guard isRunning else { return nil }
        return runOrder.first { results[$0] == nil && skipped[$0] == nil }
    }

    var hasResults: Bool { !results.isEmpty || !skipped.isEmpty }

    var totalBytesReclaimed: Int64 {
        results.values.reduce(0) { $0 + ($1.bytesReclaimed ?? 0) }
    }

    var succeededCount: Int { results.values.lazy.filter(\.succeeded).count }
    var failedCount: Int { results.values.lazy.filter { !$0.succeeded }.count + skipped.count }

    enum RowStatus: Hashable, Sendable {
        case pending
        case running
        case succeeded(MaintenanceResult)
        case failed(MaintenanceResult)
        case skipped(String)
    }

    func status(for taskID: String) -> RowStatus? {
        guard runOrder.contains(taskID) else { return nil }
        if let reason = skipped[taskID] { return .skipped(reason) }
        if let result = results[taskID] {
            return result.succeeded ? .succeeded(result) : .failed(result)
        }
        return runningTaskID == taskID ? .running : .pending
    }

    // MARK: Selection

    func isSelected(_ task: MaintenanceTask) -> Bool {
        selectedTaskIDs.contains(task.id)
    }

    func setSelected(_ selected: Bool, for task: MaintenanceTask) {
        if selected { selectedTaskIDs.insert(task.id) } else { selectedTaskIDs.remove(task.id) }
    }

    // MARK: Running

    /// Runs `tasks` in order and streams results in. Helper-only tasks are
    /// skipped (with a failed result explaining why) when the helper is missing.
    func run(_ tasks: [MaintenanceTask], helperAvailable: Bool) {
        guard !isRunning, !tasks.isEmpty else { return }
        results = [:]
        skipped = [:]
        runOrder = tasks.map(\.id)
        isRunning = true

        var runnable: [MaintenanceTask] = []
        for task in tasks {
            if task.requiresHelper, !helperAvailable {
                skipped[task.id] = "Needs the privileged helper. Install it from Settings › Advanced."
            } else {
                runnable.append(task)
            }
        }
        guard !runnable.isEmpty else {
            isRunning = false
            return
        }

        runTask = Task { [weak self] in
            let runner = MaintenanceState.makeRunner()
            for await result in await runner.run(runnable) {
                guard let self, !Task.isCancelled else { return }
                self.results[result.taskID] = result
            }
            guard let self else { return }
            self.isRunning = false
            self.runTask = nil
        }
    }

    /// Stops consuming results. The task already in flight finishes on its own
    /// (helper operations are not interruptible mid-command).
    func cancel() {
        runTask?.cancel()
        runTask = nil
        isRunning = false
    }

    func clearResults() {
        guard !isRunning else { return }
        results = [:]
        skipped = [:]
        runOrder = []
    }

    /// The runner every caller (UI, intents) uses: user-level tasks through
    /// `Process`, helper tasks through the XPC client, the caller's home folder.
    nonisolated static func makeRunner() -> MaintenanceRunner {
        MaintenanceRunner(commands: ProcessCommandRunner(),
                          helper: HelperPerformerAdapter(),
                          home: FileManager.default.homeDirectoryForCurrentUser)
    }

    static func task(withID id: String) -> MaintenanceTask? {
        MaintenanceCatalog.all.first { $0.id == id }
    }
}
