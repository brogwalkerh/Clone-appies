import AppKit
import SwiftUI
import CleanerCore
import ApplicationsModule
import DesignSystem
import UIKitBridge

/// Applications module (PLAN.md §3.5): Uninstaller · Updater · Leftovers · Installers.
///
/// Uninstaller and Updater read `AppInventoryStore`; Leftovers and Installers
/// drive `AppState.applicationsModel` (orphaned leftovers + stray installers)
/// through the shared `FindingsList`. Extensions and Reset App are later slices.
struct ApplicationsView: View {
    enum Tab: String, CaseIterable, Identifiable, Hashable {
        case uninstaller, updater, leftovers, installers

        var id: String { rawValue }

        var title: String {
            switch self {
            case .uninstaller: return "Uninstaller"
            case .updater: return "Updater"
            case .leftovers: return "Leftovers"
            case .installers: return "Installers"
            }
        }

        /// Category id prefix of the findings this tab shows, for the scan-driven tabs.
        var categoryPrefix: String? {
            switch self {
            case .leftovers: return "applications.orphaned"
            case .installers: return "applications.installers"
            case .uninstaller, .updater: return nil
            }
        }
    }

    @Environment(AppState.self) private var appState
    @AppStorage(SettingsStore.Key.removalMode) private var removalModeRaw = RemovalMode.trash.rawValue

    @State private var tab: Tab = .uninstaller
    @State private var expandedGroups: Set<String> = []
    @State private var confirmRemove = false
    @State private var confirmUninstall = false
    @State private var errorMessage: String?
    @State private var infoMessage: String?
    /// Leftovers checked in the Uninstaller detail pane for the selected app.
    @State private var checkedLeftoverIDs: Set<UUID> = []

    private var store: AppInventoryStore { appState.appInventory }
    private var model: ScanViewModel { appState.applicationsModel }

    var body: some View {
        VStack(spacing: 0) {
            ModuleTabBar(selection: $tab) { $0.title }
            content
        }
        .navigationTitle("Applications")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                switch tab {
                case .uninstaller:
                    Button("Refresh") { Task { await store.refresh() } }
                        .disabled(store.isDiscovering)
                case .updater:
                    EmptyView()
                case .leftovers, .installers:
                    if !model.findings.isEmpty, !model.isScanning {
                        Button("Select Safe Items") { model.selectAllNonRisky() }
                        Button("Rescan") { startScan() }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar
        }
        .task {
            await store.refreshIfNeeded()
        }
        .task(id: store.selectedAppID) {
            // Resolve leftovers for the newly selected app; everything found is
            // checked by default (risk .safe per the contract).
            checkedLeftoverIDs = []
            guard let app = store.selectedApp else { return }
            let found = await store.leftovers(for: app)
            if store.selectedAppID == app.id {
                checkedLeftoverIDs = Set(found.map(\.id))
            }
        }
        .onChange(of: model.summary) { _, summary in
            if let summary {
                appState.record(summary: summary, for: .applications)
            }
        }
        .onChange(of: model.groups.map(\.id)) { _, ids in
            if expandedGroups.isEmpty {
                expandedGroups = Set(ids)
            }
        }
        .removalConfirmation(isPresented: $confirmRemove,
                             count: model.selectedFindings.count,
                             bytes: model.selectedBytes,
                             mode: removalMode) {
            removeFindings()
        }
        .confirmationDialog(uninstallTitle, isPresented: $confirmUninstall, titleVisibility: .visible) {
            Button(removalMode == .trash ? "Move to Trash" : "Delete Permanently",
                   role: removalMode == .trash ? nil : .destructive) {
                uninstallSelected()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(removalMode == .trash
                 ? "The app and its checked support files go to the Trash. You can undo this until the Trash is emptied."
                 : "The app and its checked support files are deleted immediately and cannot be recovered.")
        }
        .messageAlert("Applications", message: $errorMessage)
        .messageAlert("Undo", message: $infoMessage)
    }

    // MARK: Content per tab

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .uninstaller:
            uninstaller
        case .updater:
            updater
        case .leftovers, .installers:
            scanResults(prefix: tab.categoryPrefix ?? "")
        }
    }

    // MARK: Uninstaller

    @ViewBuilder
    private var uninstaller: some View {
        @Bindable var store = store
        switch store.discovery {
        case .idle where store.apps.isEmpty, .discovering where store.apps.isEmpty:
            EmptyState.scanning("Finding installed apps…",
                                message: "Looking in /Applications, ~/Applications, Setapp and Homebrew.")
        case .failed(let message) where store.apps.isEmpty:
            EmptyState(title: "Could Not List Apps",
                       message: message,
                       style: .symbol("exclamationmark.triangle"),
                       actionTitle: "Try Again") {
                Task { await store.refresh() }
            }
        default:
            HStack(spacing: 0) {
                List(selection: $store.selectedAppID) {
                    ForEach(store.apps) { app in
                        InstalledAppRow(app: app)
                            .tag(app.id)
                    }
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds()
                .frame(minWidth: 480)

                Divider()

                appDetail
                    .frame(width: 380)
            }
        }
    }

    @ViewBuilder
    private var appDetail: some View {
        if let app = store.selectedApp {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 14) {
                        Image(nsImage: AppIconProvider.icon(for: app.bundleURL))
                            .resizable()
                            .frame(width: 64, height: 64)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(app.name)
                                .font(.title2.weight(.semibold))
                                .lineLimit(2)
                            HStack(spacing: 8) {
                                if let version = app.version {
                                    Text("Version \(version)")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                                AppSourceBadge(source: app.source)
                            }
                        }
                    }

                    GlassCard {
                        VStack(alignment: .leading, spacing: 8) {
                            detailRow("Size", ByteFormatter.string(app.sizeBytes))
                            detailRow("Last opened", app.lastOpened.map { $0.formatted(.relative(presentation: .named)) } ?? "Never")
                            detailRow("Bundle ID", app.bundleIdentifier ?? "—")
                            detailRow("Location", app.bundleURL.deletingLastPathComponent().path(percentEncoded: false))
                        }
                    }

                    if app.isSystem {
                        Label("Part of macOS. System apps cannot be uninstalled; this keeps your Mac bootable and lets macOS updates apply cleanly.",
                              systemImage: "lock.shield")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        itemsToRemove(for: app)
                    }

                    HStack {
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([app.bundleURL])
                        }
                        .buttonStyle(.glass)
                        Spacer()
                    }
                }
                .padding(20)
            }
        } else {
            EmptyState(title: "Select an App",
                       message: "Pick an app to see its support files and uninstall it with everything it left behind.",
                       style: .symbol("square.grid.2x2"))
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.callout)
    }

    @ViewBuilder
    private func itemsToRemove(for app: InstalledApp) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Items to remove")
                .font(.headline)

            HStack(spacing: 10) {
                Toggle("", isOn: .constant(true))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(true)
                    .accessibilityLabel(Text("Application bundle, always removed"))
                Image(systemName: "app")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.bundleURL.lastPathComponent)
                        .lineLimit(1)
                    Text("Application bundle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(ByteFormatter.string(app.sizeBytes))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            if store.resolvingLeftovers.contains(app.id) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for support files…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else if let leftovers = store.cachedLeftovers(for: app) {
                if leftovers.isEmpty {
                    Text("No support files found outside the bundle.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(leftovers) { finding in
                        FindingRow(finding: finding, isSelected: leftoverBinding(for: finding))
                    }
                }
            }

            Text("Removing \(selectedLeftovers.count + 1) items • \(ByteFormatter.string(uninstallBytes))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .padding(.top, 4)
        }
    }

    private func leftoverBinding(for finding: Finding) -> Binding<Bool> {
        Binding(
            get: { checkedLeftoverIDs.contains(finding.id) },
            set: { checked in
                if checked { checkedLeftoverIDs.insert(finding.id) } else { checkedLeftoverIDs.remove(finding.id) }
            })
    }

    private var selectedLeftovers: [Finding] {
        guard let app = store.selectedApp, let leftovers = store.cachedLeftovers(for: app) else { return [] }
        return leftovers.filter { checkedLeftoverIDs.contains($0.id) }
    }

    private var uninstallBytes: Int64 {
        (store.selectedApp?.sizeBytes ?? 0) + selectedLeftovers.reduce(0) { $0 + $1.sizeBytes }
    }

    private var uninstallTitle: String {
        "Uninstall \(store.selectedApp?.name ?? "app") and \(selectedLeftovers.count) support files (\(ByteFormatter.string(uninstallBytes)))?"
    }

    // MARK: Updater

    @ViewBuilder
    private var updater: some View {
        switch store.updateState {
        case .idle:
            EmptyState(title: "Check for Updates",
                       message: "Asks the App Store, each app's Sparkle feed, and Homebrew for newer versions of what you have installed.",
                       style: .symbol("arrow.up.circle"))
        case .checking:
            EmptyState.scanning("Checking \(store.apps.count) apps…",
                                message: "App Store lookups, Sparkle appcasts and brew outdated.")
        case .checked where store.updates.isEmpty:
            EmptyState.nothingFound("Everything Is Up to Date",
                                    message: "No newer versions were reported for your installed apps.",
                                    actionTitle: "Check Again") {
                Task { await store.checkForUpdates() }
            }
        case .checked:
            List(store.updates, id: \.app.id) { update in
                AvailableUpdateRow(update: update)
            }
            .listStyle(.inset)
            .alternatingRowBackgrounds()
        }
    }

    // MARK: Leftovers / Installers (scan driven)

    @ViewBuilder
    private func scanResults(prefix: String) -> some View {
        let groups = model.groups(withCategoryPrefix: prefix)
        switch model.phase {
        case .idle:
            EmptyState(title: tab == .leftovers ? "Find Orphaned Files" : "Find Stray Installers",
                       message: tab == .leftovers
                           ? "Support files, caches and preferences left behind by apps you already removed."
                           : "Disk images and packages sitting in Downloads, Desktop and Documents after the app was installed.",
                       style: .symbol(tab == .leftovers ? "app.dashed" : "shippingbox"))
        case .scanning where groups.isEmpty:
            EmptyState.scanning("Scanning…", message: model.statusLine, cancel: { model.cancel() })
        case .finished where groups.isEmpty, .cancelled where groups.isEmpty:
            EmptyState.nothingFound(
                model.phase == .cancelled ? "Scan Stopped" : "Nothing Found",
                message: model.phase == .cancelled
                    ? "The scan was stopped before it finished."
                    : (tab == .leftovers ? "No orphaned files from removed apps." : "No stray installers."),
                actionTitle: "Scan Again") {
                startScan()
            }
        default:
            FindingsList(model: model, groups: groups, expandedGroups: $expandedGroups)
        }
    }

    // MARK: Bottom bar

    @ViewBuilder
    private var bottomBar: some View {
        switch tab {
        case .uninstaller:
            BottomActionBar {
                HStack(spacing: 12) {
                    if store.lastUninstallManifest != nil {
                        Button("Undo Last Uninstall") { undoUninstall() }
                            .buttonStyle(.glass)
                            .disabled(store.isUninstalling)
                    }
                }
            } content: {
                PrimaryActionButton(store.isUninstalling ? "Uninstalling…" : "Uninstall",
                                    bytes: store.selectedApp.map { _ in uninstallBytes },
                                    isLoading: store.isUninstalling,
                                    isEnabled: canUninstall) {
                    confirmUninstall = true
                }
                .moduleTint(.applications)
                .help(store.selectedApp?.isSystem == true ? "System apps cannot be uninstalled." : "")
            }

        case .updater:
            BottomActionBar {
                HStack(spacing: 12) {
                    if case .checked(let date) = store.updateState {
                        Text("Checked \(date.formatted(.relative(presentation: .named)))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            } content: {
                PrimaryActionButton(store.isCheckingUpdates ? "Checking…" : "Check for Updates",
                                    isLoading: store.isCheckingUpdates) {
                    Task { await store.checkForUpdates() }
                }
                .moduleTint(.applications)
            }

        case .leftovers, .installers:
            FindingsActionBar(model: model, tint: .applications,
                              cleanTitle: "Remove",
                              removingTitle: "Removing…",
                              undoTitle: "Undo Last Removal",
                              onScan: { startScan() },
                              onClean: { confirmRemove = true },
                              onUndo: { undoFindings() })
        }
    }

    private var canUninstall: Bool {
        guard let app = store.selectedApp else { return false }
        return !app.isSystem && !store.isUninstalling
    }

    private var subtitle: String {
        switch tab {
        case .uninstaller:
            return store.apps.isEmpty ? "Installed apps" : "\(store.apps.count) apps • \(store.removableApps.count) removable"
        case .updater:
            return store.updates.isEmpty ? "Updates" : "\(store.updates.count) updates available"
        case .leftovers, .installers:
            if model.isScanning { return "Scanning…" }
            let findings = model.findings(withCategoryPrefix: tab.categoryPrefix ?? "")
            guard !findings.isEmpty else { return tab.title }
            let bytes = findings.reduce(Int64(0)) { $0 + $1.sizeBytes }
            return "\(ByteFormatter.string(bytes)) found • \(ByteFormatter.string(model.selectedBytes)) selected overall"
        }
    }

    // MARK: Actions

    private var removalMode: RemovalMode {
        RemovalMode(rawValue: removalModeRaw) ?? .trash
    }

    private func startScan() {
        expandedGroups = []
        model.context = SettingsStore.scanContext()
        model.run()
    }

    private func removeFindings() {
        let mode = removalMode
        Task {
            if case .error(let message) = await FindingsActions.clean(model, mode: mode, appState: appState, moduleTitle: "Applications cleanup") {
                errorMessage = message
            }
        }
    }

    private func undoFindings() {
        Task {
            switch await FindingsActions.undo(model, appState: appState) {
            case .info(let message): infoMessage = message
            case .error(let message): errorMessage = message
            }
        }
    }

    private func uninstallSelected() {
        guard let app = store.selectedApp else { return }
        let leftovers = selectedLeftovers
        let mode = removalMode
        Task {
            do {
                let manifest = try await store.uninstall(app, leftovers: leftovers,
                                                         using: FindingsActions.makeRemover(), mode: mode)
                appState.lastRemovalManifests[.applications] = manifest
                appState.post(title: "Uninstalled \(app.name)",
                              message: "Reclaimed \(ByteFormatter.string(manifest.bytesReclaimed)).")
                let failed = manifest.records.filter { !$0.succeeded }
                if !failed.isEmpty {
                    errorMessage = "\(failed.count) item(s) could not be removed. \(failed.first?.error ?? "")"
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func undoUninstall() {
        Task {
            do {
                let restored = try await store.undoLastUninstall(using: FindingsActions.makeRemover())
                let count = restored.filter(\.succeeded).count
                infoMessage = "Restored \(count) of \(restored.count) items from the Trash."
                await store.refresh()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Rows

struct InstalledAppRow: View {
    let app: InstalledApp

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: AppIconProvider.icon(for: app.bundleURL))
                .resizable()
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(app.name)
                        .lineLimit(1)
                    AppSourceBadge(source: app.source)
                }
                Text(app.version.map { "Version \($0)" } ?? "Version unknown")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(app.lastOpened.map { "Opened \($0.formatted(.relative(presentation: .named)))" } ?? "Never opened")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .trailing)

            Text(ByteFormatter.string(app.sizeBytes))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .help(app.bundleURL.path(percentEncoded: false))
        .accessibilityElement(children: .combine)
    }
}

struct AvailableUpdateRow: View {
    let update: AvailableUpdate

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: AppIconProvider.icon(for: update.app.bundleURL))
                .resizable()
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(update.app.name)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(update.app.version ?? "?")
                        .monospacedDigit()
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                    Text(update.latestVersion)
                        .monospacedDigit()
                        .fontWeight(.semibold)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            AppSourceBadge(source: update.source)

            if let url = update.releaseNotesURL ?? update.downloadURL {
                Button("Open") {
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .help(url.absoluteString)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

struct AppSourceBadge: View {
    let source: AppSource

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
            .accessibilityLabel(Text("Source: \(label)"))
    }

    private var label: String {
        switch source {
        case .appStore: return "App Store"
        case .direct: return "Direct"
        case .homebrewCask: return "Homebrew"
        case .setapp: return "Setapp"
        case .system: return "System"
        case .unknown: return "Unknown"
        }
    }

    private var color: Color {
        switch source {
        case .appStore: return .blue
        case .direct: return .purple
        case .homebrewCask: return .orange
        case .setapp: return .teal
        case .system: return .gray
        case .unknown: return .secondary
        }
    }
}

#Preview {
    ApplicationsView()
        .environment(AppState())
        .frame(width: 1200, height: 800)
}
