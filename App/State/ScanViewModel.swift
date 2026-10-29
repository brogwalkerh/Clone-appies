import Foundation
import Observation
import CleanerCore
import SmartCareModule

/// Findings of one category plus derived totals, ready for a disclosure group.
struct FindingGroup: Identifiable, Hashable, Sendable {
    let category: FindingCategory
    let findings: [Finding]

    var id: String { category.id }
    var totalBytes: Int64 { findings.reduce(0) { $0 + $1.sizeBytes } }
}

/// Drives one module's scan: consumes `ScanCoordinator.run` events, groups
/// findings by category, tracks the user's selection, and performs removal
/// with an undo manifest. UI-facing, so `@MainActor`.
@MainActor
@Observable
final class ScanViewModel {
    enum Phase: Hashable, Sendable {
        case idle
        case scanning
        case finished
        case cancelled
    }

    let module: ModuleID

    private(set) var phase: Phase = .idle
    private(set) var findings: [Finding] = []
    private(set) var summary: ScanSummary?
    private(set) var scannerErrors: [String: String] = [:]
    private(set) var isRemoving = false
    private(set) var removalProgress: Double?
    private(set) var lastManifest: RemovalManifest?
    private(set) var lastError: String?

    /// IDs of findings the user has checked. Non-risky findings are selected by default.
    var selectedIDs: Set<UUID> = []

    /// Context for the next run. Refresh from settings before `run()` if needed.
    var context: ScanContext

    var isScanning: Bool { phase == .scanning }

    /// 0...1 across all scanners, or `nil` while indeterminate.
    var progress: Double? {
        guard phase == .scanning, scannerCount > 0 else { return nil }
        var total = 0.0
        var determinate = false
        for id in scannerIDs {
            if finishedScanners.contains(id) {
                total += 1
                determinate = true
            } else if let fraction = scannerFractions[id] ?? nil {
                total += fraction
                determinate = true
            }
        }
        return determinate ? min(total / Double(scannerCount), 1) : nil
    }

    /// Groups sorted by reclaimable bytes, largest first.
    var groups: [FindingGroup] {
        Dictionary(grouping: findings, by: \.category)
            .map { FindingGroup(category: $0.key, findings: $0.value.sorted { $0.sizeBytes > $1.sizeBytes }) }
            .sorted { $0.totalBytes > $1.totalBytes }
    }

    var totalBytes: Int64 {
        findings.reduce(0) { $0 + $1.sizeBytes }
    }

    var selectedFindings: [Finding] {
        findings.filter { selectedIDs.contains($0.id) }
    }

    var selectedBytes: Int64 {
        selectedFindings.reduce(0) { $0 + $1.sizeBytes }
    }

    // MARK: Private

    private var coordinator: ScanCoordinator
    private var scannerIDs: [String]
    private var scannerCount: Int { scannerIDs.count }
    private var scannerFractions: [String: Double?] = [:]
    private var finishedScanners: Set<String> = []
    private var cancelRequested = false
    private var runTask: Task<Void, Never>?

    init(module: ModuleID, coordinator: ScanCoordinator, context: ScanContext, scannerIDs: [String] = []) {
        self.module = module
        self.coordinator = coordinator
        self.context = context
        self.scannerIDs = scannerIDs
    }

    /// Convenience that also records scanner IDs for progress math.
    /// `CleanerScanner` is `CleanerCore.Scanner`; the bare name collides with `Foundation.Scanner`.
    convenience init(module: ModuleID, scanners: [any CleanerScanner], context: ScanContext) {
        self.init(module: module,
                  coordinator: ScanCoordinator(scanners: scanners),
                  context: context,
                  scannerIDs: scanners.map { type(of: $0).id })
    }

    // MARK: Scanning

    /// Starts a run (or joins the one in flight) and returns when it ends.
    /// Smart Care uses this to scan every module at once.
    func runToCompletion() async {
        run()
        await runTask?.value
    }

    func run() {
        guard phase != .scanning else { return }
        runTask?.cancel()
        findings = []
        selectedIDs = []
        summary = nil
        scannerErrors = [:]
        scannerFractions = [:]
        finishedScanners = []
        cancelRequested = false
        lastError = nil
        phase = .scanning

        let context = self.context
        runTask = Task { [weak self] in
            guard let self else { return }
            for await event in await coordinator.run(context) {
                handle(event)
            }
            if phase == .scanning {
                // Stream ended without `.completed` (should not happen; the
                // coordinator always finishes with it, even after cancel).
                phase = .cancelled
            }
        }
    }

    /// Asks the coordinator to stop. The coordinator then emits `.finished` with
    /// partial counts for interrupted scanners followed by `.completed`, so the
    /// run loop ends normally and partial findings stay available.
    func cancel() {
        guard phase == .scanning else { return }
        cancelRequested = true
        let coordinator = self.coordinator
        Task { await coordinator.cancel() }
    }

    func reset() {
        runTask?.cancel()
        runTask = nil
        let coordinator = self.coordinator
        Task { await coordinator.cancel() }
        findings = []
        selectedIDs = []
        summary = nil
        scannerErrors = [:]
        phase = .idle
    }

    /// Swaps the scanner set used by the *next* run (e.g. My Clutter's Large & Old
    /// thresholds changed). A run in progress is stopped; results already on
    /// screen stay until the user scans again, so moving a slider never wipes
    /// a list the user is working through.
    func replaceScanners(_ scanners: [any CleanerScanner]) {
        if phase == .scanning {
            cancel()
        }
        coordinator = ScanCoordinator(scanners: scanners)
        scannerIDs = scanners.map { type(of: $0).id }
        scannerFractions = [:]
        finishedScanners = []
    }

    private func handle(_ event: ScanEvent) {
        switch event {
        case .started(let scannerID):
            scannerFractions[scannerID] = .some(nil)

        case .finding(let finding):
            findings.append(finding)
            if finding.risk != .risky {
                selectedIDs.insert(finding.id)
            }

        case .progress(let scannerID, let fraction):
            scannerFractions[scannerID] = .some(fraction)

        case .finished(let scannerID, _, _):
            finishedScanners.insert(scannerID)

        case .failed(let scannerID, let message):
            scannerErrors[scannerID] = message
            finishedScanners.insert(scannerID)

        case .completed(let scanSummary):
            summary = scanSummary
            phase = cancelRequested ? .cancelled : .finished
            runTask = nil
            if !cancelRequested {
                ActivityCenter.shared.record(.scan(scanSummary, module: module))
            }
        }
    }

    // MARK: Selection

    func isSelected(_ finding: Finding) -> Bool {
        selectedIDs.contains(finding.id)
    }

    func setSelected(_ selected: Bool, for finding: Finding) {
        if selected {
            selectedIDs.insert(finding.id)
        } else {
            selectedIDs.remove(finding.id)
        }
    }

    enum GroupSelection: Hashable { case none, some, all }

    func selectionState(for group: FindingGroup) -> GroupSelection {
        selectionState(for: group.findings)
    }

    /// Selection state of an arbitrary subset, e.g. one duplicate group keyed by keeper.
    func selectionState(for findings: [Finding]) -> GroupSelection {
        let count = findings.lazy.filter { self.selectedIDs.contains($0.id) }.count
        if count == 0 { return .none }
        return count == findings.count ? .all : .some
    }

    func setSelected(_ selected: Bool, for group: FindingGroup) {
        setSelected(selected, for: group.findings)
    }

    func setSelected(_ selected: Bool, for findings: [Finding]) {
        let ids = findings.map(\.id)
        if selected {
            selectedIDs.formUnion(ids)
        } else {
            selectedIDs.subtract(ids)
        }
    }

    func selectAllNonRisky() {
        selectedIDs = Set(findings.lazy.filter { $0.risk != .risky }.map(\.id))
    }

    // MARK: Removal

    /// Removes the selected findings, stores the manifest for Undo, and drops the
    /// successfully removed findings from the list.
    @discardableResult
    func remove(using remover: any Remover, mode: RemovalMode = .trash) async throws -> RemovalManifest {
        let targets = selectedFindings
        guard !targets.isEmpty else {
            throw RemovalError.nothingSelected
        }
        isRemoving = true
        removalProgress = 0
        lastError = nil
        defer {
            isRemoving = false
            removalProgress = nil
        }

        let manifest: RemovalManifest
        do {
            manifest = try await remover.remove(targets, mode: mode) { [weak self] done, total in
                Task { @MainActor in
                    self?.removalProgress = total > 0 ? Double(done) / Double(total) : nil
                }
            }
        } catch {
            lastError = error.localizedDescription
            throw error
        }

        lastManifest = manifest
        ActivityCenter.shared.record(.removal(manifest, module: module))
        let removedIDs = Set(manifest.records.lazy.filter(\.succeeded).map(\.finding.id))
        findings.removeAll { removedIDs.contains($0.id) }
        selectedIDs.subtract(removedIDs)
        return manifest
    }

    /// Best-effort restore of the last removal from Trash.
    @discardableResult
    func undoLastRemoval(using remover: any Remover) async throws -> [RemovalRecord] {
        guard let manifest = lastManifest else {
            throw RemovalError.nothingToUndo
        }
        isRemoving = true
        defer { isRemoving = false }
        do {
            let restored = try await remover.undo(manifest)
            lastManifest = nil
            ActivityCenter.shared.record(.undo(restored, module: module))
            return restored
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    enum RemovalError: LocalizedError {
        case nothingSelected
        case nothingToUndo

        var errorDescription: String? {
            switch self {
            case .nothingSelected: return "Nothing is selected."
            case .nothingToUndo: return "There is no cleanup to undo."
            }
        }
    }
}
