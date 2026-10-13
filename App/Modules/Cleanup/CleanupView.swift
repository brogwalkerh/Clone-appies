import SwiftUI
import CleanerCore
import CleanupModule
import DesignSystem

/// Cleanup module: categories as disclosure groups, per-finding checkboxes,
/// one primary action that reads "Scan" → "Clean 12.4 GB", and Undo.
/// The `ScanViewModel` lives on `AppState` (built from `CleanupScanners.all()`)
/// so a running scan survives sidebar navigation. List, rows, bottom bar and
/// the removal flow are the shared pieces in `Modules/Shared/FindingsList.swift`.
struct CleanupView: View {
    @Environment(AppState.self) private var appState
    @AppStorage(SettingsStore.Key.removalMode) private var removalModeRaw = RemovalMode.trash.rawValue

    @State private var expandedGroups: Set<String> = []
    @State private var confirmClean = false
    @State private var errorMessage: String?
    @State private var infoMessage: String?

    private var model: ScanViewModel { appState.cleanup }

    var body: some View {
        content
            .navigationTitle("Cleanup")
            .navigationSubtitle(subtitle)
            .toolbar {
                ToolbarItemGroup(placement: .automatic) {
                    if !model.findings.isEmpty, !model.isScanning {
                        Button("Select Safe Items") { model.selectAllNonRisky() }
                        Button("Rescan") { startScan() }
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                FindingsActionBar(model: model, tint: .cleanup,
                                  onScan: { startScan() },
                                  onClean: { confirmClean = true },
                                  onUndo: { undo() })
            }
            .onChange(of: model.summary) { _, summary in
                if let summary {
                    appState.record(summary: summary, for: .cleanup)
                    if !model.findings.isEmpty {
                        appState.post(title: "Cleanup scan finished",
                                      message: "\(ByteFormatter.string(summary.totalBytes)) in \(summary.totalFindings) items can be removed.")
                    }
                }
            }
            .onChange(of: model.groups.map(\.id)) { _, ids in
                // Expand the first few categories automatically as they appear.
                if expandedGroups.isEmpty {
                    expandedGroups = Set(ids.prefix(3))
                }
            }
            .removalConfirmation(isPresented: $confirmClean,
                                 count: model.selectedFindings.count,
                                 bytes: model.selectedBytes,
                                 mode: removalMode) {
                clean()
            }
            .messageAlert("Cleanup", message: $errorMessage)
            .messageAlert("Undo", message: $infoMessage)
    }

    // MARK: States

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle where appState.permissions.fullDiskAccess == .denied:
            EmptyState.needsPermission(
                "Full Disk Access",
                message: "Without it, caches, Mail attachments, and other apps' containers stay hidden. You can still scan what is visible.") {
                PermissionChecker.openSystemSettings(for: .fullDiskAccess)
            }

        case .idle:
            EmptyState(title: "Ready to Scan",
                       message: "Looks for caches, logs, crash reports, Xcode and AI-tool leftovers, broken downloads, Trash contents, and more.",
                       style: .symbol("trash"))

        case .scanning where model.findings.isEmpty:
            EmptyState.scanning("Scanning for junk…",
                                message: model.statusLine,
                                cancel: { model.cancel() })

        case .finished where model.findings.isEmpty, .cancelled where model.findings.isEmpty:
            EmptyState.nothingFound(
                model.phase == .cancelled ? "Scan Stopped" : "Nothing to Clean",
                message: model.phase == .cancelled
                    ? "The scan was stopped before it finished."
                    : "Your Mac is already tidy. Check back after a few days of use.",
                actionTitle: "Scan Again") {
                startScan()
            }

        default:
            FindingsList(model: model, expandedGroups: $expandedGroups)
        }
    }

    private var subtitle: String {
        switch model.phase {
        case .idle: return "System junk"
        case .scanning: return "Scanning…"
        case .finished, .cancelled:
            return model.findings.isEmpty
                ? "Nothing found"
                : "\(ByteFormatter.string(model.totalBytes)) found • \(ByteFormatter.string(model.selectedBytes)) selected"
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

    private func clean() {
        let mode = removalMode
        Task {
            if case .error(let message) = await FindingsActions.clean(model, mode: mode, appState: appState, moduleTitle: "Cleanup") {
                errorMessage = message
            }
        }
    }

    private func undo() {
        Task {
            switch await FindingsActions.undo(model, appState: appState) {
            case .info(let message): infoMessage = message
            case .error(let message): errorMessage = message
            }
        }
    }
}

#Preview {
    CleanupView()
        .environment(AppState())
        .frame(width: 1000, height: 760)
}
