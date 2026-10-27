import AppKit
import SwiftUI
import CleanerCore
import DesignSystem
import HelperProtocol
import PerformanceModule
import UIKitBridge

/// Performance module (PLAN.md §3.4): Maintenance · Login Items · Heavy Consumers · Hung Apps.
///
/// Maintenance drives `AppState.maintenance` (`MaintenanceState`) so a run keeps
/// streaming results while the user navigates away. Login Items reads launchd
/// plists through `BackgroundItemsInventory`; Heavy Consumers and Hung Apps share
/// one `ProcessMonitor` that polls `DarwinProcessSampler` every 3 s while visible.
/// Tab layout follows `ApplicationsView` (UI-SPEC.md §3.3).
struct PerformanceView: View {
    enum Tab: String, CaseIterable, Identifiable, Hashable {
        case maintenance, loginItems, heavyConsumers, hungApps

        var id: String { rawValue }

        var title: String {
            switch self {
            case .maintenance: return "Maintenance"
            case .loginItems: return "Login Items"
            case .heavyConsumers: return "Heavy Consumers"
            case .hungApps: return "Hung Apps"
            }
        }

        /// Tabs that need the process sampler running.
        var usesProcessMonitor: Bool {
            self == .heavyConsumers || self == .hungApps
        }
    }

    @Environment(AppState.self) private var appState
    @AppStorage(SettingsStore.Key.removalMode) private var removalModeRaw = RemovalMode.trash.rawValue

    @State private var tab: Tab = .maintenance
    @State private var backgroundItems = BackgroundItemsStore()
    @State private var processMonitor = ProcessMonitor()
    @State private var confirmRemoveBroken = false
    @State private var confirmForceQuitAll = false
    @State private var errorMessage: String?
    @State private var infoMessage: String?

    private var maintenance: MaintenanceState { appState.maintenance }
    private var helperAvailable: Bool { HelperClient.shared.isAvailable }

    var body: some View {
        VStack(spacing: 0) {
            ModuleTabBar(selection: $tab) { $0.title }
            content
        }
        .navigationTitle("Performance")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                switch tab {
                case .maintenance:
                    Button("Select Safe Tasks") { selectSafeTasks() }
                        .disabled(maintenance.isRunning)
                    if maintenance.hasResults, !maintenance.isRunning {
                        Button("Clear Results") { maintenance.clearResults() }
                    }
                case .loginItems:
                    Button("Refresh") { Task { await backgroundItems.refresh() } }
                        .disabled(backgroundItems.isLoading)
                case .heavyConsumers, .hungApps:
                    Button("Refresh") { Task { await processMonitor.sampleOnce() } }
                        .disabled(processMonitor.isSampling)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar
        }
        .task {
            await HelperClient.shared.checkAvailability()
            // Cheap plist-only scan (broken login items) so Smart Care's Performance
            // card has a status; Login Items itself reads the inventory directly.
            if appState.performanceModel.phase == .idle {
                appState.performanceModel.context = SettingsStore.scanContext()
                appState.performanceModel.run()
            }
        }
        .onChange(of: appState.performanceModel.summary) { _, summary in
            if let summary {
                appState.record(summary: summary, for: .performance)
            }
        }
        .task(id: tab) {
            // Poll the process list only while a process tab is on screen; leaving
            // the tab (or the module) cancels this task and stops sampling.
            guard tab.usesProcessMonitor else { return }
            await processMonitor.poll(every: .seconds(3))
        }
        .task(id: tab == .loginItems) {
            if tab == .loginItems {
                await backgroundItems.refreshIfNeeded()
            }
        }
        .onChange(of: maintenance.pendingFocusTaskID, initial: true) { _, taskID in
            consumePendingFocus(taskID)
        }
        .removalConfirmation(isPresented: $confirmRemoveBroken,
                             count: backgroundItems.removableBrokenFindings.count,
                             bytes: backgroundItems.removableBrokenFindings.reduce(Int64(0)) { $0 + $1.sizeBytes },
                             mode: removalMode) {
            removeBrokenItems()
        }
        .confirmationDialog("Force quit \(processMonitor.hung.count) unresponsive apps?",
                            isPresented: $confirmForceQuitAll,
                            titleVisibility: .visible) {
            Button("Force Quit All", role: .destructive) {
                for sample in processMonitor.hung {
                    processMonitor.forceQuit(sample)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Unsaved changes in those apps will be lost.")
        }
        .messageAlert("Performance", message: $errorMessage)
        .messageAlert("Performance", message: $infoMessage)
    }

    // MARK: Content per tab

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .maintenance:
            MaintenanceTab(maintenance: maintenance,
                           helperAvailable: helperAvailable,
                           onInstallHelper: { appState.requestHelperInstall() })
        case .loginItems:
            BackgroundItemsTab(store: backgroundItems,
                               helperAvailable: helperAvailable,
                               onInstallHelper: { appState.requestHelperInstall() },
                               onError: { errorMessage = $0 })
        case .heavyConsumers:
            HeavyConsumersTab(monitor: processMonitor, onError: { errorMessage = $0 })
        case .hungApps:
            HungAppsTab(monitor: processMonitor, onError: { errorMessage = $0 })
        }
    }

    // MARK: Bottom bar

    @ViewBuilder
    private var bottomBar: some View {
        switch tab {
        case .maintenance:
            BottomActionBar {
                HStack(spacing: 12) {
                    if maintenance.isRunning {
                        Button("Stop") { maintenance.cancel() }
                            .buttonStyle(.glass)
                    } else if maintenance.hasResults {
                        Text(maintenanceSummaryLine)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            } content: {
                PrimaryActionButton(maintenancePrimaryTitle,
                                    isLoading: maintenance.isRunning,
                                    isEnabled: !runnableSelectedTasks.isEmpty) {
                    runSelectedTasks()
                }
                .moduleTint(.performance)
                .help(runnableSelectedTasks.isEmpty && !maintenance.selectedTaskIDs.isEmpty
                      ? "The selected tasks need the privileged helper." : "")
            }

        case .loginItems:
            BottomActionBar {
                Button("Manage in System Settings") { BackgroundItemsStore.openLoginItemsSettings() }
                    .buttonStyle(.glass)
            } content: {
                let broken = backgroundItems.removableBrokenFindings
                PrimaryActionButton(backgroundItems.isRemoving ? "Removing…" : "Remove \(broken.count) Broken Items",
                                    isLoading: backgroundItems.isRemoving,
                                    isEnabled: !broken.isEmpty && !backgroundItems.isLoading) {
                    confirmRemoveBroken = true
                }
                .moduleTint(.performance)
                .help(broken.isEmpty ? "Broken items are launch agents whose program no longer exists." : "")
            }

        case .heavyConsumers:
            BottomActionBar {
                if let date = processMonitor.lastSampledAt {
                    Text("Updated \(date.formatted(.relative(presentation: .named)))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } content: {
                PrimaryActionButton("Refresh", isLoading: processMonitor.isSampling) {
                    Task { await processMonitor.sampleOnce() }
                }
                .moduleTint(.performance)
            }

        case .hungApps:
            BottomActionBar {
                if let date = processMonitor.lastSampledAt {
                    Text("Checked \(date.formatted(.relative(presentation: .named)))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } content: {
                PrimaryActionButton("Force Quit All",
                                    isLoading: processMonitor.isSampling && processMonitor.samples.isEmpty,
                                    isEnabled: !processMonitor.hung.isEmpty) {
                    confirmForceQuitAll = true
                }
                .moduleTint(.performance)
            }
        }
    }

    // MARK: Derived

    private var subtitle: String {
        switch tab {
        case .maintenance:
            if maintenance.isRunning {
                return "Running \(maintenance.results.count + 1) of \(maintenance.runOrder.count)…"
            }
            if maintenance.hasResults { return maintenanceSummaryLine }
            return "\(maintenance.selectedTaskIDs.count) of \(MaintenanceCatalog.all.count) tasks selected"
        case .loginItems:
            if backgroundItems.isLoading, backgroundItems.items.isEmpty { return "Reading launch agents…" }
            let broken = backgroundItems.items.lazy.filter(\.isBroken).count
            return "\(backgroundItems.items.count) items • \(broken) broken"
        case .heavyConsumers:
            return processMonitor.heavy.isEmpty ? "Live CPU and memory" : "\(processMonitor.heavy.count) heavy processes"
        case .hungApps:
            return processMonitor.hung.isEmpty ? "No unresponsive apps" : "\(processMonitor.hung.count) unresponsive"
        }
    }

    private var maintenanceSummaryLine: String {
        var parts = ["\(maintenance.succeededCount) succeeded"]
        if maintenance.failedCount > 0 { parts.append("\(maintenance.failedCount) failed") }
        if maintenance.totalBytesReclaimed > 0 {
            parts.append("reclaimed \(ByteFormatter.string(maintenance.totalBytesReclaimed))")
        }
        return parts.joined(separator: " • ")
    }

    private var maintenancePrimaryTitle: String {
        if maintenance.isRunning { return "Running…" }
        let count = runnableSelectedTasks.count
        return count == 1 ? "Run 1 task" : "Run \(count) tasks"
    }

    /// Selected tasks that can actually run right now (helper tasks need the helper).
    private var runnableSelectedTasks: [MaintenanceTask] {
        maintenance.selectedTasks.filter { !$0.requiresHelper || helperAvailable }
    }

    private var removalMode: RemovalMode {
        RemovalMode(rawValue: removalModeRaw) ?? .trash
    }

    // MARK: Actions

    private func runSelectedTasks() {
        let tasks = runnableSelectedTasks
        guard !tasks.isEmpty else { return }
        maintenance.run(tasks, helperAvailable: helperAvailable)
    }

    private func selectSafeTasks() {
        maintenance.selectedTaskIDs = Set(MaintenanceCatalog.all
            .filter { $0.risk == .safe && (!$0.requiresHelper || helperAvailable) }
            .map(\.id))
    }

    /// `maccleaner://performance?task=<id>`: focus Maintenance, run the task if it
    /// can run, otherwise show the helper install step.
    private func consumePendingFocus(_ taskID: String?) {
        guard let taskID, let task = MaintenanceState.task(withID: taskID) else { return }
        maintenance.pendingFocusTaskID = nil
        tab = .maintenance
        Task {
            await HelperClient.shared.checkAvailability()
            if task.requiresHelper, !HelperClient.shared.isAvailable {
                appState.requestHelperInstall()
            } else {
                maintenance.run([task], helperAvailable: HelperClient.shared.isAvailable)
            }
        }
    }

    private func removeBrokenItems() {
        let mode = removalMode
        Task {
            do {
                let manifest = try await backgroundItems.removeBrokenItems(using: FindingsActions.makeRemover(), mode: mode)
                appState.lastRemovalManifests[.performance] = manifest
                let removed = manifest.records.filter(\.succeeded).count
                appState.post(title: "Removed broken login items",
                              message: "\(removed) launch agent plist(s) moved to the Trash.")
                let failed = manifest.records.filter { !$0.succeeded }
                if !failed.isEmpty {
                    errorMessage = "\(failed.count) item(s) could not be removed. \(failed.first?.error ?? "")"
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Small capsule badge used across the Performance tabs ("Needs helper", "Broken", "Apple", "System", …).
struct PerformanceBadge: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
            .accessibilityLabel(Text(text))
    }
}

#Preview {
    PerformanceView()
        .environment(AppState())
        .frame(width: 1200, height: 800)
}
