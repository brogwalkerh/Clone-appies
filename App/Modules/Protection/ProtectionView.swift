import AppKit
import SwiftUI
import CleanerCore
import DesignSystem
import ProtectionModule

/// Protection module (PLAN.md §3.3): Malware · Privacy · Permissions · Monitor.
///
/// Malware drives `AppState.malware` (`MalwareScanModel`) and Privacy drives
/// `AppState.privacyModel` (a `ScanViewModel` over `PrivacyScanners.all()`), so
/// both keep running while the user navigates away. Permissions reads the TCC
/// database through `TCCPermissionsReader` on demand; Monitor only configures
/// the FSEvents monitor that lives in the menu bar agent and polls the shared
/// suite for its status while the tab is visible. Tab layout follows
/// `PerformanceView` (UI-SPEC.md §3.6).
struct ProtectionView: View {
    enum Tab: String, CaseIterable, Identifiable, Hashable {
        case malware, privacy, permissions, monitor

        var id: String { rawValue }

        var title: String {
            switch self {
            case .malware: return "Malware"
            case .privacy: return "Privacy"
            case .permissions: return "Permissions"
            case .monitor: return "Monitor"
            }
        }
    }

    @Environment(AppState.self) private var appState
    @AppStorage(SettingsStore.Key.removalMode) private var removalModeRaw = RemovalMode.trash.rawValue
    // Absent means on, matching the agent's `AgentState.SharedSettings.isMonitorEnabled()`.
    @AppStorage(MenuAgentSettings.Key.monitorEnabled, store: MenuAgentSettings.store) private var monitorEnabled = true

    @State private var tab: Tab = .malware
    @State private var permissions = PermissionsStore()
    @State private var monitorStatus = MonitorStatusReader()
    @State private var agent = MenuAgentController()
    @State private var expandedPrivacyGroups: Set<String> = []
    @State private var showQuarantine = false
    @State private var confirmQuarantine = false
    @State private var confirmPrivacyRemoval = false
    @State private var errorMessage: String?
    @State private var infoMessage: String?

    private var malware: MalwareScanModel { appState.malware }
    private var privacy: ScanViewModel { appState.privacyModel }

    var body: some View {
        @Bindable var malware = malware

        VStack(spacing: 0) {
            ModuleTabBar(selection: $tab) { $0.title }
            content
        }
        .navigationTitle("Protection")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                switch tab {
                case .malware:
                    if malware.hasResults, !malware.isScanning {
                        Button("Select All") { malware.selectAll() }
                    }
                    Button(malware.quarantinedCount > 0 ? "Quarantine (\(malware.quarantinedCount))" : "Quarantine…") {
                        showQuarantine = true
                    }
                    .help("Restore or permanently delete quarantined items")
                case .privacy:
                    if !privacy.findings.isEmpty, !privacy.isScanning {
                        Button("Select Safe Items") { privacy.selectAllNonRisky() }
                        Button("Rescan") { startPrivacyScan() }
                    }
                case .permissions:
                    Button("Refresh") { Task { await permissions.refresh() } }
                        .disabled(permissions.isLoading)
                case .monitor:
                    EmptyView()
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar
        }
        .task {
            // Load signatures once per launch and tidy the quarantine folder by retention.
            await malware.loadDatabaseIfNeeded()
            await malware.refreshQuarantine()
            await malware.autoUpdateIfDue()
        }
        .task(id: tab == .permissions) {
            if tab == .permissions {
                await permissions.refreshIfNeeded()
            }
        }
        .task(id: tab == .monitor) {
            // Poll the agent's status keys only while the Monitor tab is on screen.
            guard tab == .monitor else { return }
            agent.refresh()
            await monitorStatus.poll(every: .seconds(2))
        }
        .onChange(of: malware.pendingFocus, initial: true) { _, pending in
            if pending {
                tab = .malware
                malware.pendingFocus = false
            }
        }
        .onChange(of: malware.phase) { _, phase in
            malwarePhaseChanged(phase)
        }
        .onChange(of: privacy.summary) { _, summary in
            if let summary, !privacy.findings.isEmpty {
                appState.post(title: "Privacy scan finished",
                              message: "\(summary.totalFindings) items of browsing and app history can be removed.")
            }
        }
        .onChange(of: privacy.groups.map(\.id)) { _, ids in
            if expandedPrivacyGroups.isEmpty {
                expandedPrivacyGroups = Set(ids.prefix(3))
            }
        }
        .sheet(isPresented: $showQuarantine) {
            QuarantineSheet(model: malware)
        }
        .confirmationDialog(quarantineTitle, isPresented: $confirmQuarantine, titleVisibility: .visible) {
            Button("Quarantine") { quarantineSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Items move to the app's quarantine folder with all permissions removed, so they can no longer run or open. You can restore them from the Quarantine window.")
        }
        .removalConfirmation(isPresented: $confirmPrivacyRemoval,
                             count: privacy.selectedFindings.count,
                             bytes: privacy.selectedBytes,
                             mode: removalMode) {
            removePrivacyItems()
        }
        .messageAlert("Protection", message: $errorMessage)
        .messageAlert("Protection", message: $infoMessage)
        .messageAlert("Protection", message: $malware.lastError)
    }

    // MARK: Content per tab

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .malware:
            MalwareTab(model: malware, onScan: { startMalwareScan() })
        case .privacy:
            PrivacyTab(model: privacy,
                       expandedGroups: $expandedPrivacyGroups,
                       fullDiskAccessDenied: appState.permissions.fullDiskAccess == .denied,
                       onScan: { startPrivacyScan() })
        case .permissions:
            PermissionsTab(store: permissions)
        case .monitor:
            MonitorTab(isEnabled: $monitorEnabled,
                       agentEnabled: agent.isEnabled,
                       status: monitorStatus,
                       onOpenMenu: { appState.select(.menuApp) })
        }
    }

    // MARK: Bottom bar

    @ViewBuilder
    private var bottomBar: some View {
        switch tab {
        case .malware:
            BottomActionBar {
                HStack(spacing: 12) {
                    if malware.isScanning {
                        Button("Stop") { malware.cancel() }
                            .buttonStyle(.glass)
                    } else if let manifest = malware.lastQuarantineManifest {
                        Button("Show Quarantine") { showQuarantine = true }
                            .buttonStyle(.glass)
                        Text("Quarantined \(manifest.records.lazy.filter(\.succeeded).count) items")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            } content: {
                PrimaryActionButton(malwarePrimaryTitle,
                                    isLoading: malware.isScanning || malware.isQuarantining,
                                    isEnabled: malwarePrimaryEnabled) {
                    if malware.hasResults {
                        confirmQuarantine = true
                    } else {
                        startMalwareScan()
                    }
                }
                .moduleTint(.protection)
                .help(malware.hasResults && malware.selectedThreats.isEmpty ? "Select at least one threat to quarantine." : "")
            }

        case .privacy:
            FindingsActionBar(model: privacy,
                              tint: .protection,
                              cleanTitle: "Remove",
                              removingTitle: "Removing…",
                              undoTitle: "Undo Last Removal",
                              onScan: { startPrivacyScan() },
                              onClean: { confirmPrivacyRemoval = true },
                              onUndo: { undoPrivacyRemoval() })

        case .permissions:
            BottomActionBar {
                if let date = permissions.lastLoadedAt {
                    Text("Read \(date.formatted(.relative(presentation: .named)))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } content: {
                PrimaryActionButton("Refresh", isLoading: permissions.isLoading) {
                    Task { await permissions.refresh() }
                }
                .moduleTint(.protection)
            }

        case .monitor:
            BottomActionBar {
                Button("Open Menu Settings") { appState.select(.menuApp) }
                    .buttonStyle(.glass)
            } content: {
                PrimaryActionButton(monitorEnabled ? "Disable Monitor" : "Enable Monitor") {
                    monitorEnabled.toggle()
                }
                .moduleTint(.protection)
                .help(agent.isEnabled ? "" : "The monitor runs inside the menu bar agent, which is not enabled.")
            }
        }
    }

    // MARK: Derived

    private var subtitle: String {
        switch tab {
        case .malware:
            switch malware.phase {
            case .idle:
                return "\(malware.scope.title) scan"
            case .scanning:
                return malware.threats.isEmpty
                    ? "Scanning \(malware.roots.count) locations…"
                    : "Scanning… \(malware.threats.count) threats so far"
            case .finished, .cancelled:
                if malware.threats.isEmpty {
                    return malware.phase == .cancelled ? "Scan stopped" : "No threats found"
                }
                return "\(malware.threats.count) threats • \(malware.selectedThreats.count) selected"
            case .failed:
                return "Scan failed"
            }
        case .privacy:
            switch privacy.phase {
            case .idle: return "Browsing and app history"
            case .scanning: return "Scanning…"
            case .finished, .cancelled:
                return privacy.findings.isEmpty
                    ? "Nothing found"
                    : "\(ByteFormatter.string(privacy.totalBytes)) found • \(ByteFormatter.string(privacy.selectedBytes)) selected"
            }
        case .permissions:
            if permissions.isLoading, permissions.grants.isEmpty { return "Reading permissions…" }
            let granted = permissions.grants.lazy.filter(\.granted).count
            return permissions.grants.isEmpty ? "App permissions" : "\(granted) grants across \(permissions.groups.count) services"
        case .monitor:
            return monitorStatus.statusLine(monitorEnabled: monitorEnabled, agentEnabled: agent.isEnabled)
        }
    }

    private var malwarePrimaryTitle: String {
        if malware.isQuarantining { return "Quarantining…" }
        if malware.isScanning { return "Scanning…" }
        if malware.hasResults {
            let count = malware.selectedThreats.count
            return count == 1 ? "Quarantine 1 threat" : "Quarantine \(count) threats"
        }
        return malware.phase == .idle ? "Scan" : "Scan Again"
    }

    private var malwarePrimaryEnabled: Bool {
        if malware.hasResults { return !malware.selectedThreats.isEmpty }
        return true
    }

    private var quarantineTitle: String {
        let count = malware.selectedThreats.count
        return "Quarantine \(count) \(count == 1 ? "threat" : "threats") (\(ByteFormatter.string(malware.selectedBytes)))?"
    }

    private var removalMode: RemovalMode {
        RemovalMode(rawValue: removalModeRaw) ?? .trash
    }

    // MARK: Actions

    private func startMalwareScan() {
        malware.run()
    }

    private func malwarePhaseChanged(_ phase: MalwareScanModel.Phase) {
        switch phase {
        case .finished, .cancelled:
            if let summary = malware.summary {
                appState.record(summary: summary, for: .protection)
            }
            if !malware.threats.isEmpty {
                let count = malware.threats.count
                appState.post(title: "Malware scan finished",
                              message: count == 1 ? "1 threat found. Review it in Protection." : "\(count) threats found. Review them in Protection.")
            }
        case .failed(let message):
            errorMessage = message
        case .idle, .scanning:
            break
        }
    }

    private func quarantineSelected() {
        Task {
            guard let manifest = await malware.quarantineSelected() else { return }
            let done = manifest.records.filter(\.succeeded).count
            appState.post(title: "Threats quarantined",
                          message: "\(done) item(s) moved to quarantine. Restore or delete them from Protection › Quarantine.")
            if let summary = malware.summary {
                appState.record(summary: summary, for: .protection)
            }
        }
    }

    private func startPrivacyScan() {
        expandedPrivacyGroups = []
        privacy.context = SettingsStore.scanContext()
        privacy.run()
    }

    private func removePrivacyItems() {
        let mode = removalMode
        Task {
            if case .error(let message) = await FindingsActions.clean(privacy, mode: mode, appState: appState, moduleTitle: "Privacy cleanup") {
                errorMessage = message
            }
        }
    }

    private func undoPrivacyRemoval() {
        Task {
            switch await FindingsActions.undo(privacy, appState: appState) {
            case .info(let message): infoMessage = message
            case .error(let message): errorMessage = message
            }
        }
    }
}

extension ScanScope {
    var title: String {
        switch self {
        case .quick: return "Quick"
        case .normal: return "Normal"
        case .deep: return "Deep"
        }
    }

    /// One line under the scope picker (CONTRACTS.md `ScanScopeResolver`).
    var explanation: String {
        switch self {
        case .quick:
            return "Running apps, login items and launch agents, Downloads, Desktop, and apps changed in the last week. About a minute."
        case .normal:
            return "Everything in Quick plus your home folder, Applications, system launch agents and daemons, and /usr/local."
        case .deep:
            return "Everything in Normal plus every mounted volume. Can take a long time on large external disks."
        }
    }
}

#Preview {
    ProtectionView()
        .environment(AppState())
        .frame(width: 1200, height: 800)
}
