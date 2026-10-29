import Foundation
import Observation
import CleanerCore
import ProtectionModule
import SmartCareModule

/// Smart Care in the app (PLAN.md §3.1): one Scan runs every module's
/// existing view model at once, so each card opens a module screen that
/// already holds its results; one Run cleans what `SmartCarePolicy` selects.
///
/// The CLI drives `SmartCareCoordinator` instead; both share the policy, so
/// "what Run removes" means the same thing everywhere.
@MainActor
@Observable
final class SmartCareModel {
    enum Phase: Hashable, Sendable {
        case idle
        case scanning
        case scanned
        case cleaning
        case cleaned(bytes: Int64)
    }

    private(set) var phase: Phase = .idle
    private(set) var lastScanDate: Date?
    /// Set when Run could not remove everything; the screen shows and clears it.
    var lastCleanupError: String?

    @ObservationIgnored weak var appState: AppState?
    @ObservationIgnored let policy = SmartCarePolicy.default

    init() {
        lastScanDate = SettingsStore.lastSmartCareScan()
    }

    var isBusy: Bool { phase == .scanning || phase == .cleaning }

    /// Mean progress of the module scans (indeterminate ones count as half done).
    var progress: Double? {
        guard phase == .scanning, let appState else { return nil }
        let models = [appState.cleanup, appState.performanceModel, appState.applicationsModel, appState.clutterModel]
        var values = models.map { model -> Double in
            if !model.isScanning { return 1 }
            return model.progress ?? 0.5
        }
        values.append(appState.malware.isScanning ? 0.5 : 1)
        return values.reduce(0, +) / Double(values.count)
    }

    /// The models whose selection Run removes (Cleanup and Performance, per the policy).
    private var cleanableModels: [ScanViewModel] {
        guard let appState else { return [] }
        return [appState.cleanup, appState.performanceModel].filter { !policy.isReviewOnly($0.module) }
    }

    /// What Run would remove right now: each cleanable module's current selection.
    var selectedBytes: Int64 {
        cleanableModels.reduce(0) { $0 + $1.selectedBytes }
    }

    var selectedCount: Int {
        cleanableModels.reduce(0) { $0 + $1.selectedIDs.count }
    }

    // MARK: Scan

    /// Scans Cleanup, Protection (quick), Performance, Applications (leftovers,
    /// installers and updates) and My Clutter concurrently.
    func scan() async {
        guard let appState, !isBusy else { return }
        phase = .scanning
        lastCleanupError = nil
        let context = SettingsStore.scanContext()
        appState.restoreFullCleanupScanners()
        for model in [appState.cleanup, appState.performanceModel, appState.applicationsModel, appState.clutterModel] {
            model.context = context
        }
        let malware = appState.malware
        let userScope = malware.scope
        if !malware.isScanning { malware.scope = .quick }

        let cleanupModel = appState.cleanup
        let performanceModel = appState.performanceModel
        let applicationsModel = appState.applicationsModel
        let clutterModel = appState.clutterModel
        let inventory = appState.appInventory
        async let cleanup: Void = cleanupModel.runToCompletion()
        async let performance: Void = performanceModel.runToCompletion()
        async let applications: Void = applicationsModel.runToCompletion()
        async let clutter: Void = clutterModel.runToCompletion()
        async let threats: Void = malware.runToCompletion()
        async let updates: Void = inventory.checkForUpdates()
        _ = await (cleanup, performance, applications, clutter, threats, updates)

        malware.scope = userScope
        for model in [appState.cleanup, appState.performanceModel, appState.applicationsModel, appState.clutterModel] {
            if let summary = model.summary { appState.record(summary: summary, for: model.module) }
        }
        if let summary = malware.summary { appState.record(summary: summary, for: .protection) }

        let now = Date.now
        lastScanDate = now
        SettingsStore.setLastSmartCareScan(now)
        phase = .scanned
    }

    // MARK: Run

    /// Removes the current selection of Cleanup and Performance. Threats,
    /// leftovers and clutter stay for review in their modules.
    func clean(mode: RemovalMode) async {
        guard let appState, !isBusy else { return }
        phase = .cleaning
        lastCleanupError = nil
        var reclaimed: Int64 = 0
        for model in cleanableModels where !model.selectedIDs.isEmpty {
            let outcome = await FindingsActions.clean(model, mode: mode, appState: appState,
                                                      moduleTitle: model.module.displayName)
            reclaimed += model.lastManifest?.bytesReclaimed ?? 0
            if case .error(let message)? = outcome {
                lastCleanupError = message
            }
        }
        phase = .cleaned(bytes: reclaimed)
    }

    // MARK: Summary text

    /// One line for notifications and Siri: what the last scan found.
    func resultSummary() -> String {
        guard let appState else { return "" }
        var parts: [String] = []
        let junk = selectedBytes
        parts.append(junk > 0 ? "\(ByteFormatter.string(junk)) of junk can be removed" : "no junk to remove")
        let threats = appState.malware.threats.count
        if threats > 0 { parts.append(threats == 1 ? "1 threat found" : "\(threats) threats found") }
        let updates = appState.appInventory.updates.count
        if updates > 0 { parts.append(updates == 1 ? "1 app update" : "\(updates) app updates") }
        let clutter = appState.clutterModel.totalBytes
        if clutter > 0 { parts.append("\(ByteFormatter.string(clutter)) of clutter to review") }
        return parts.joined(separator: ", ").capitalizedFirst + "."
    }
}

private extension String {
    var capitalizedFirst: String {
        prefix(1).uppercased() + dropFirst()
    }
}
