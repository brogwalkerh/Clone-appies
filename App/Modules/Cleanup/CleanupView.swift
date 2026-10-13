import AppKit
import SwiftUI
import CleanerCore
import CleanupModule
import DesignSystem

/// Cleanup module: categories as disclosure groups, per-finding checkboxes,
/// one primary action that reads "Scan" → "Clean 12.4 GB", and Undo.
/// The `ScanViewModel` lives on `AppState` (built from `CleanupScanners.all()`)
/// so a running scan survives sidebar navigation.
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
                bottomBar
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
            .confirmationDialog(confirmTitle, isPresented: $confirmClean, titleVisibility: .visible) {
                Button(removalMode == .trash ? "Move to Trash" : "Delete Permanently",
                       role: removalMode == .trash ? nil : .destructive) {
                    clean()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(removalMode == .trash
                     ? "Items go to the Trash. You can undo this cleanup until the Trash is emptied."
                     : "Items are deleted immediately and cannot be recovered.")
            }
            .alert("Cleanup", isPresented: isPresented($errorMessage)) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .alert("Undo", isPresented: isPresented($infoMessage)) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(infoMessage ?? "")
            }
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
                                message: scannerStatusLine,
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
            results
        }
    }

    private var results: some View {
        VStack(spacing: 0) {
            if model.isScanning {
                HStack(spacing: 12) {
                    ProgressView(value: model.progress)
                        .progressViewStyle(.linear)
                    Text(scannerStatusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(.bar)
                Divider()
            }

            List {
                ForEach(model.groups) { group in
                    DisclosureGroup(isExpanded: expansionBinding(for: group.id)) {
                        ForEach(group.findings) { finding in
                            FindingRow(finding: finding, isSelected: selectionBinding(for: finding))
                        }
                    } label: {
                        CategoryHeader(group: group,
                                       state: model.selectionState(for: group)) {
                            model.setSelected(model.selectionState(for: group) != .all, for: group)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .alternatingRowBackgrounds()

            if !model.scannerErrors.isEmpty {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text("\(model.scannerErrors.count) scanner(s) reported errors: \(model.scannerErrors.values.joined(separator: "; "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
        }
    }

    private var scannerStatusLine: String {
        if let progress = model.progress {
            return "\(Int(progress * 100))% • \(model.findings.count) items • \(ByteFormatter.string(model.totalBytes))"
        }
        return "\(model.findings.count) items • \(ByteFormatter.string(model.totalBytes))"
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

    // MARK: Bottom bar

    private var bottomBar: some View {
        BottomActionBar {
            HStack(spacing: 12) {
                if model.isScanning {
                    Button("Stop") { model.cancel() }
                        .buttonStyle(.glass)
                } else if let manifest = model.lastManifest {
                    Button("Undo Last Cleanup") { undo() }
                        .buttonStyle(.glass)
                        .disabled(model.isRemoving)
                    Text("Reclaimed \(ByteFormatter.string(manifest.bytesReclaimed))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        } content: {
            PrimaryActionButton(primaryTitle,
                                bytes: primaryBytes,
                                isLoading: model.isScanning || model.isRemoving,
                                isEnabled: primaryEnabled) {
                primaryAction()
            }
            .moduleTint(.cleanup)
        }
    }

    private var hasResults: Bool { !model.findings.isEmpty }

    private var primaryTitle: String {
        if model.isRemoving { return "Cleaning…" }
        if model.isScanning { return "Scanning…" }
        if hasResults { return "Clean" }
        return model.phase == .idle ? "Scan" : "Scan Again"
    }

    private var primaryBytes: Int64? {
        hasResults && !model.isScanning ? model.selectedBytes : nil
    }

    private var primaryEnabled: Bool {
        if hasResults { return model.selectedBytes > 0 || !model.selectedFindings.isEmpty }
        return true
    }

    private func primaryAction() {
        if hasResults {
            confirmClean = true
        } else {
            startScan()
        }
    }

    private var confirmTitle: String {
        "Remove \(model.selectedFindings.count) items (\(ByteFormatter.string(model.selectedBytes)))?"
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
        let remover = GuardedRemover(wrapping: TrashRemover(), protectedPaths: .default)
        let mode = removalMode
        Task {
            do {
                let manifest = try await model.remove(using: remover, mode: mode)
                appState.lastCleanupManifest = manifest
                appState.post(title: "Cleanup finished",
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

    private func undo() {
        let remover = GuardedRemover(wrapping: TrashRemover(), protectedPaths: .default)
        Task {
            do {
                let restored = try await model.undoLastRemoval(using: remover)
                let count = restored.filter(\.succeeded).count
                appState.lastCleanupManifest = nil
                infoMessage = "Restored \(count) of \(restored.count) items from the Trash. Run a new scan to see them again."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Bindings

    private func expansionBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { expandedGroups.contains(id) },
            set: { expanded in
                if expanded { expandedGroups.insert(id) } else { expandedGroups.remove(id) }
            })
    }

    private func selectionBinding(for finding: Finding) -> Binding<Bool> {
        Binding(
            get: { model.isSelected(finding) },
            set: { model.setSelected($0, for: finding) })
    }

    private func isPresented(_ message: Binding<String?>) -> Binding<Bool> {
        Binding(
            get: { message.wrappedValue != nil },
            set: { if !$0 { message.wrappedValue = nil } })
    }
}

// MARK: - Rows

struct CategoryHeader: View {
    let group: FindingGroup
    let state: ScanViewModel.GroupSelection
    let toggle: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: toggle) {
                Image(systemName: checkboxSymbol)
                    .font(.title3)
                    .foregroundStyle(state == .none
                                     ? AnyShapeStyle(HierarchicalShapeStyle.secondary)
                                     : AnyShapeStyle(Color.accentColor))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(state == .all ? "Deselect all in \(group.category.displayName)" : "Select all in \(group.category.displayName)")

            Image(systemName: CategoryHeader.symbol(for: group.category.id))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(group.category.displayName)
                .font(.headline)
            Text("\(group.findings.count) items")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(ByteFormatter.string(group.totalBytes))
                .font(.system(.body, design: .rounded).weight(.medium))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .padding(.vertical, 4)
    }

    private var checkboxSymbol: String {
        switch state {
        case .none: return "square"
        case .some: return "minus.square.fill"
        case .all: return "checkmark.square.fill"
        }
    }

    /// Picks a symbol from the category id suffix (e.g. "cleanup.userCaches").
    static func symbol(for categoryID: String) -> String {
        let key = categoryID.lowercased()
        if key.contains("cache") { return "archivebox" }
        if key.contains("log") { return "doc.text" }
        if key.contains("crash") { return "exclamationmark.triangle" }
        if key.contains("trash") { return "trash" }
        if key.contains("xcode") || key.contains("derived") { return "hammer" }
        if key.contains("mail") { return "envelope" }
        if key.contains("download") { return "arrow.down.circle" }
        if key.contains("language") || key.contains("locali") { return "globe" }
        if key.contains("backup") || key.contains("ios") { return "iphone" }
        if key.contains("ai") || key.contains("model") || key.contains("ollama") { return "brain" }
        if key.contains("docker") || key.contains("brew") { return "shippingbox" }
        return "folder"
    }
}

struct FindingRow: View {
    let finding: Finding
    @Binding var isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: $isSelected)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel(Text(finding.path.lastPathComponent))

            Image(systemName: finding.isDirectory ? "folder" : "doc")
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(finding.path.lastPathComponent)
                    .lineLimit(1)
                Text(finding.detail ?? finding.path.deletingLastPathComponent().path(percentEncoded: false))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            RiskBadge(risk: finding.risk)

            Text(ByteFormatter.string(finding.sizeBytes))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([finding.path])
            }
            Button(isSelected ? "Deselect" : "Select") {
                isSelected.toggle()
            }
        }
        .help(finding.path.path(percentEncoded: false))
    }
}

struct RiskBadge: View {
    let risk: RiskLevel

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
            .accessibilityLabel(Text("Risk: \(label)"))
    }

    private var label: String {
        switch risk {
        case .safe: return "Safe"
        case .caution: return "Caution"
        case .risky: return "Risky"
        }
    }

    private var color: Color {
        switch risk {
        case .safe: return .green
        case .caution: return .orange
        case .risky: return .red
        }
    }
}

#Preview {
    CleanupView()
        .environment(AppState())
        .frame(width: 1000, height: 760)
}
