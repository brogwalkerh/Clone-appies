import SwiftUI
import CleanerCore
import DesignSystem
import SmartCareModule

/// Home screen (PLAN.md §3.1): hero ring, five module cards, the Assistant and
/// My Tools action sets. Scan runs every module at once; Run cleans what
/// `SmartCarePolicy` selects (Cleanup and Performance), the rest is reviewed
/// in its module.
struct SmartCareView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @AppStorage(SettingsStore.Key.removalMode) private var removalModeRaw = RemovalMode.trash.rawValue

    @State private var confirmClean = false
    /// Bumped after a dismissal so the Assistant re-reads the dismissal file.
    @State private var dismissals = 0

    private let moduleItems: [SidebarItem] = [.cleanup, .protection, .performance, .applications, .myClutter]

    private var smartCare: SmartCareModel { appState.smartCare }
    private var removalMode: RemovalMode { RemovalMode(rawValue: removalModeRaw) ?? .trash }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                hero
                moduleCards
                AssistantPanel(recommendations: recommendations) { id in
                    appState.dismissRecommendation(id)
                    dismissals += 1
                }
                ActionSetsPanel()
            }
            .padding(32)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Smart Care")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            BottomActionBar {
                if smartCare.phase == .scanned, smartCare.selectedCount > 0 {
                    Button("Scan Again") { startScan() }
                        .buttonStyle(.glass)
                }
            } content: {
                PrimaryActionButton(primaryTitle,
                                    bytes: showsRunBytes ? smartCare.selectedBytes : nil,
                                    isLoading: smartCare.isBusy) {
                    primaryAction()
                }
                .disabled(smartCare.isBusy)
            }
        }
        .removalConfirmation(isPresented: $confirmClean,
                             count: smartCare.selectedCount,
                             bytes: smartCare.selectedBytes,
                             mode: removalMode) {
            Task { await smartCare.clean(mode: removalMode) }
        }
        .messageAlert("Some items were not removed", message: Binding(
            get: { smartCare.lastCleanupError },
            set: { smartCare.lastCleanupError = $0 }))
    }

    // MARK: Primary action

    private var showsRunBytes: Bool {
        smartCare.phase == .scanned && smartCare.selectedCount > 0
    }

    private var primaryTitle: String {
        switch smartCare.phase {
        case .idle: return "Scan"
        case .scanning: return "Scanning…"
        case .cleaning: return "Cleaning…"
        case .scanned: return smartCare.selectedCount > 0 ? "Run" : "Scan Again"
        case .cleaned: return "Scan Again"
        }
    }

    private func primaryAction() {
        if showsRunBytes {
            confirmClean = true
        } else {
            startScan()
        }
    }

    private func startScan() {
        Task { await smartCare.scan() }
    }

    // MARK: Hero

    private var hero: some View {
        HStack(alignment: .center, spacing: 40) {
            ScanRing(phase: ringPhase,
                     tint: ModuleTint.accent.color(for: scheme, contrast: contrast),
                     diameter: 240)

            VStack(alignment: .leading, spacing: 14) {
                Text("Smart Care")
                    .font(.largeTitle.weight(.bold))
                Text(heroText)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    StatPill(systemImage: "trash",
                             value: junkValue,
                             caption: "Junk found",
                             tint: ModuleTint.cleanup.color(for: scheme, contrast: contrast))
                    StatPill(systemImage: "shield",
                             value: threatsValue,
                             caption: "Threats",
                             tint: ModuleTint.protection.color(for: scheme, contrast: contrast))
                    StatPill(systemImage: "arrow.up.circle",
                             value: updatesValue,
                             caption: "Updates",
                             tint: ModuleTint.applications.color(for: scheme, contrast: contrast))
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var heroText: String {
        switch smartCare.phase {
        case .idle:
            if let last = smartCare.lastScanDate {
                return "Last scan \(last.formatted(.relative(presentation: .named, unitsStyle: .wide))). Scan again to check for junk, threats, slowdowns, outdated apps and clutter."
            }
            return "One scan checks for junk, threats, slowdowns, outdated apps and clutter, then shows a single result you can act on."
        case .scanning:
            return "Scanning every module at once…"
        case .scanned:
            return smartCare.resultSummary()
        case .cleaning:
            return "Moving the selected items to the Trash…"
        case .cleaned(let bytes):
            return bytes > 0
                ? "Done. \(ByteFormatter.string(bytes)) reclaimed. Threats, leftovers and clutter are waiting for review in their modules."
                : "Nothing was removed."
        }
    }

    private var ringPhase: ScanRing.Phase {
        switch smartCare.phase {
        case .scanning:
            return .scanning(fraction: smartCare.progress)
        case .cleaning:
            return .scanning(fraction: nil)
        case .scanned:
            let parts = ByteText.components(smartCare.selectedBytes)
            return .result(value: parts.value, unit: parts.unit, caption: "can be cleaned")
        case .cleaned(let bytes):
            let parts = ByteText.components(bytes)
            return .result(value: parts.value, unit: parts.unit, caption: "cleaned")
        case .idle:
            return .idle
        }
    }

    private var junkValue: String {
        switch smartCare.phase {
        case .scanning: return "…"
        case .scanned: return ByteFormatter.string(smartCare.selectedBytes)
        default: return appState.lastScanSummaries[.cleanup].map { ByteFormatter.string($0.totalBytes) } ?? "—"
        }
    }

    /// "—" until a malware scan has run, then the number of open threats.
    private var threatsValue: String {
        if appState.malware.isScanning { return "…" }
        guard appState.lastScanSummaries[.protection] != nil else { return "—" }
        return "\(appState.malware.threats.count)"
    }

    private var updatesValue: String {
        if appState.appInventory.isCheckingUpdates { return "…" }
        guard case .checked = appState.appInventory.updateState else { return "—" }
        return "\(appState.appInventory.updates.count)"
    }

    // MARK: Module cards

    private var moduleCards: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 5), spacing: 14) {
            ForEach(moduleItems) { item in
                Button {
                    appState.select(item)
                } label: {
                    ModuleCard(item: item, status: status(for: item))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("\(item.title), \(status(for: item).text)"))
            }
        }
    }

    private func status(for item: SidebarItem) -> ModuleCard.Status {
        if item == .protection {
            return protectionStatus
        }
        let model: ScanViewModel?
        let moduleID: ModuleID?
        switch item {
        case .cleanup:      (model, moduleID) = (appState.cleanup, .cleanup)
        case .applications: (model, moduleID) = (appState.applicationsModel, .applications)
        case .performance:  (model, moduleID) = (appState.performanceModel, .performance)
        case .myClutter:    (model, moduleID) = (appState.clutterModel, .clutter)
        default:            (model, moduleID) = (nil, nil)
        }
        guard let model, let moduleID else { return .notScanned }
        if model.isScanning { return .scanning }
        if moduleID == .performance, appState.maintenance.isRunning { return .scanning }
        if let summary = appState.lastScanSummaries[moduleID] {
            switch moduleID {
            case .performance:
                // Performance findings are broken login items; bytes are meaningless there.
                return summary.totalFindings == 0
                    ? .clean
                    : .result("\(summary.totalFindings) broken login items")
            case .applications:
                let updates = appState.appInventory.updates.count
                let leftovers = summary.totalFindings == 0 ? nil : "\(ByteFormatter.string(summary.totalBytes)) to review"
                let text = [leftovers, updates > 0 ? "\(updates) updates" : nil].compactMap { $0 }.joined(separator: " · ")
                return text.isEmpty ? .clean : .result(text)
            case .clutter:
                return summary.totalFindings == 0 ? .clean : .result("\(ByteFormatter.string(summary.totalBytes)) to review")
            default:
                return summary.totalFindings == 0
                    ? .clean
                    : .result("\(ByteFormatter.string(summary.totalBytes)) to clean")
            }
        }
        if moduleID == .performance, appState.maintenance.hasResults {
            let bytes = appState.maintenance.totalBytesReclaimed
            return bytes > 0 ? .result("Reclaimed \(ByteFormatter.string(bytes))") : .clean
        }
        return .notScanned
    }

    /// Protection's card reads the malware model (threat count) rather than a `ScanViewModel`.
    private var protectionStatus: ModuleCard.Status {
        let malware = appState.malware
        if malware.isScanning || appState.privacyModel.isScanning { return .scanning }
        if appState.lastScanSummaries[.protection] != nil {
            let open = malware.threats.count
            if open == 0 { return .clean }
            return .result(open == 1 ? "1 threat found" : "\(open) threats found")
        }
        return .notScanned
    }

    // MARK: Assistant (rule-based, PLAN.md §3.1)

    private var recommendations: [AssistantRecommendation] {
        _ = dismissals
        return Assistant().recommendations(for: appState.assistantSnapshot(),
                                           dismissed: appState.dismissedRecommendations())
    }
}

// MARK: - Module card

struct ModuleCard: View {
    enum Status: Hashable {
        case notScanned
        case scanning
        case clean
        case result(String)

        var text: String {
            switch self {
            case .notScanned: return "Not scanned yet"
            case .scanning: return "Scanning…"
            case .clean: return "Nothing to clean"
            case .result(let text): return text
            }
        }

        var systemImage: String {
            switch self {
            case .notScanned: return "circle.dashed"
            case .scanning: return "arrow.triangle.2.circlepath"
            case .clean: return "checkmark.circle.fill"
            case .result: return "exclamationmark.circle.fill"
            }
        }
    }

    let item: SidebarItem
    let status: Status

    var body: some View {
        ResolvedTint(item.tint) { tint in
            GlassCard(tint: tint, padding: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: item.systemImage)
                            .font(.title2)
                            .foregroundStyle(tint)
                        Spacer()
                        if status == .scanning {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: status.systemImage)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(item.title)
                        .font(.headline)
                    Text(status.text)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .contentTransition(.numericText())
                }
                .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
            }
        }
    }
}

// MARK: - Assistant

struct AssistantPanel: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openSettings) private var openSettings
    let recommendations: [AssistantRecommendation]
    let onDismiss: (String) -> Void

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                Label("Assistant", systemImage: "lightbulb")
                    .font(.headline)
                if recommendations.isEmpty {
                    Text("No recommendations right now. Your Mac is in good shape.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(recommendations) { recommendation in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: recommendation.symbol)
                                .frame(width: 22)
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(recommendation.title).font(.subheadline.weight(.semibold))
                                Text(recommendation.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            actionButton(for: recommendation.action)
                            Button {
                                onDismiss(recommendation.id)
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.borderless)
                            .help("Hide this for a week")
                            .accessibilityLabel(Text("Dismiss \(recommendation.title)"))
                        }
                        if recommendation.id != recommendations.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func actionButton(for action: AssistantAction) -> some View {
        switch action {
        case .open(let destination):
            Button("Open") { open(destination) }
                .buttonStyle(.glass)
                .controlSize(.small)
        case .grantFullDiskAccess:
            Button("Open System Settings") { PermissionChecker.openSystemSettings(for: .fullDiskAccess) }
                .buttonStyle(.glass)
                .controlSize(.small)
        case .installHelper:
            Button("Install") { appState.requestHelperInstall() }
                .buttonStyle(.glass)
                .controlSize(.small)
        case .runSmartCare:
            Button("Scan") { Task { await appState.smartCare.scan() } }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(appState.smartCare.isBusy)
        case .updateSignatures:
            Button("Update") { Task { await appState.malware.updateSignatures() } }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(appState.malware.isUpdatingSignatures)
        }
    }

    private func open(_ destination: AssistantDestination) {
        switch destination {
        case .smartCare: appState.select(.smartCare)
        case .cleanup: appState.select(.cleanup)
        case .protection: appState.select(.protection)
        case .performance: appState.select(.performance)
        case .applications: appState.select(.applications)
        case .clutter: appState.select(.myClutter)
        case .spaceLens: appState.select(.spaceLens)
        case .myActivity: appState.select(.myActivity)
        case .scheduler: openSettings()
        }
    }
}

#Preview {
    SmartCareView()
        .environment(AppState())
        .frame(width: 1000, height: 800)
}
