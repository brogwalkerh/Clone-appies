import AppKit
import SwiftUI
import CleanerCore
import DesignSystem

// Shared result-list pieces for every module that drives a `ScanViewModel`
// (Cleanup, Applications › Leftovers / Installers, My Clutter). One
// implementation so checkboxes, risk badges, progress strips and the removal
// flow look and behave the same everywhere (UI-SPEC.md §3).

// MARK: - FindingsList

/// Progress strip (while scanning) + categories as disclosure groups with
/// per-finding checkboxes + scanner-error footer.
struct FindingsList: View {
    let model: ScanViewModel
    let groups: [FindingGroup]
    @Binding var expandedGroups: Set<String>

    /// - Parameter groups: the subset to show; `nil` shows every group in the model.
    init(model: ScanViewModel, groups: [FindingGroup]? = nil, expandedGroups: Binding<Set<String>>) {
        self.model = model
        self.groups = groups ?? model.groups
        self._expandedGroups = expandedGroups
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.isScanning {
                ScanProgressStrip(model: model)
                Divider()
            }

            List {
                ForEach(groups) { group in
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
                ScannerErrorsFooter(errors: model.scannerErrors)
            }
        }
    }

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
}

// MARK: - Progress strip and error footer

/// Linear progress plus "42% • 120 items • 3.1 GB" while results stream in.
struct ScanProgressStrip: View {
    let model: ScanViewModel

    var body: some View {
        HStack(spacing: 12) {
            ProgressView(value: model.progress)
                .progressViewStyle(.linear)
                .accessibilityAddTraits(.updatesFrequently)
            Text(model.statusLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

struct ScannerErrorsFooter: View {
    let errors: [String: String]

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text("\(errors.count) scanner(s) reported errors: \(errors.values.joined(separator: "; "))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }
}

extension ScanViewModel {
    /// "42% • 120 items • 3.1 GB" (percentage omitted while indeterminate).
    var statusLine: String {
        if let progress {
            return "\(Int(progress * 100))% • \(findings.count) items • \(ByteFormatter.string(totalBytes))"
        }
        return "\(findings.count) items • \(ByteFormatter.string(totalBytes))"
    }

    /// Groups whose category id starts with `prefix`, e.g. "clutter.downloads".
    func groups(withCategoryPrefix prefix: String) -> [FindingGroup] {
        groups.filter { $0.category.id.hasPrefix(prefix) }
    }

    /// Findings whose category id starts with `prefix`.
    func findings(withCategoryPrefix prefix: String) -> [Finding] {
        findings.filter { $0.category.id.hasPrefix(prefix) }
    }
}

// MARK: - Rows

struct CategoryHeader: View {
    let group: FindingGroup
    let state: ScanViewModel.GroupSelection
    let toggle: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 10) {
            SelectionCheckbox(state: state, label: group.category.displayName, toggle: toggle)

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
        if key.contains("installer") { return "shippingbox" }
        if key.contains("orphan") || key.contains("leftover") { return "app.dashed" }
        if key.contains("duplicate") { return "doc.on.doc" }
        if key.contains("similar") || key.contains("image") { return "photo.on.rectangle" }
        if key.contains("largeold") || key.contains("large") { return "doc.badge.ellipsis" }
        return "folder"
    }
}

/// Tri-state checkbox used by category and keeper-group headers.
struct SelectionCheckbox: View {
    let state: ScanViewModel.GroupSelection
    let label: String
    let toggle: @MainActor () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(state == .none
                                 ? AnyShapeStyle(HierarchicalShapeStyle.secondary)
                                 : AnyShapeStyle(Color.accentColor))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(state == .all ? "Deselect all in \(label)" : "Select all in \(label)")
    }

    private var symbol: String {
        switch state {
        case .none: return "square"
        case .some: return "minus.square.fill"
        case .all: return "checkmark.square.fill"
        }
    }
}

struct FindingRow: View {
    let finding: Finding
    @Binding var isSelected: Bool
    @State private var showInsight = false

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

            Button {
                showInsight = true
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .help("What is this?")
            .accessibilityLabel(Text("What is \(finding.path.lastPathComponent)?"))
            .popover(isPresented: $showInsight, arrowEdge: .trailing) {
                InsightView(finding: finding)
            }

            RiskBadge(risk: finding.risk)

            Text(ByteFormatter.string(finding.sizeBytes))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("What Is This?") {
                showInsight = true
            }
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

// MARK: - Bottom bar

/// The standard module bottom bar for a `ScanViewModel`: Stop while scanning,
/// Undo + "Reclaimed X" after a removal, and one primary button that reads
/// "Scan" → "Scanning…" → "Clean 12.4 GB" → "Scan Again".
struct FindingsActionBar: View {
    let model: ScanViewModel
    let tint: ModuleTint
    var scanTitle = "Scan"
    var cleanTitle = "Clean"
    var removingTitle = "Cleaning…"
    var undoTitle = "Undo Last Cleanup"
    /// Bytes shown on the primary button; defaults to the model's selected bytes.
    var selectedBytes: Int64?
    let onScan: @MainActor () -> Void
    let onClean: @MainActor () -> Void
    let onUndo: @MainActor () -> Void

    var body: some View {
        BottomActionBar {
            HStack(spacing: 12) {
                if model.isScanning {
                    Button("Stop") { model.cancel() }
                        .buttonStyle(.glass)
                } else if let manifest = model.lastManifest {
                    Button(undoTitle) { onUndo() }
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
                if hasResults {
                    onClean()
                } else {
                    onScan()
                }
            }
            .moduleTint(tint)
        }
    }

    private var hasResults: Bool { !model.findings.isEmpty }

    private var primaryTitle: String {
        if model.isRemoving { return removingTitle }
        if model.isScanning { return "Scanning…" }
        if hasResults { return cleanTitle }
        return model.phase == .idle ? scanTitle : "Scan Again"
    }

    private var primaryBytes: Int64? {
        hasResults && !model.isScanning ? (selectedBytes ?? model.selectedBytes) : nil
    }

    private var primaryEnabled: Bool {
        if hasResults { return !model.selectedFindings.isEmpty }
        return true
    }
}

// MARK: - Removal flow

/// Trash-or-delete confirmation shared by every module (ADR 0003).
struct RemovalConfirmation: ViewModifier {
    @Binding var isPresented: Bool
    let count: Int
    let bytes: Int64
    let mode: RemovalMode
    let confirm: @MainActor () -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog("Remove \(count) items (\(ByteFormatter.string(bytes)))?",
                                   isPresented: $isPresented,
                                   titleVisibility: .visible) {
            Button(mode == .trash ? "Move to Trash" : "Delete Permanently",
                   role: mode == .trash ? nil : .destructive) {
                confirm()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(mode == .trash
                 ? "Items go to the Trash; anything already in the Trash is deleted. You can undo the rest until the Trash is emptied."
                 : "Items are deleted immediately and cannot be recovered.")
        }
    }
}

/// One-button alert bound to an optional message; dismissing clears the message.
struct MessageAlert: ViewModifier {
    let title: String
    @Binding var message: String?

    func body(content: Content) -> some View {
        content.alert(title, isPresented: $message.isPresent) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }
}

extension View {
    func removalConfirmation(isPresented: Binding<Bool>,
                             count: Int,
                             bytes: Int64,
                             mode: RemovalMode,
                             confirm: @escaping @MainActor () -> Void) -> some View {
        modifier(RemovalConfirmation(isPresented: isPresented, count: count, bytes: bytes, mode: mode, confirm: confirm))
    }

    func messageAlert(_ title: String, message: Binding<String?>) -> some View {
        modifier(MessageAlert(title: title, message: message))
    }
}

extension Binding where Value == String? {
    /// `true` while the optional holds a message; setting `false` clears it.
    var isPresent: Binding<Bool> {
        Binding<Bool>(
            get: { wrappedValue != nil },
            set: { if !$0 { wrappedValue = nil } })
    }
}

/// Remove / undo actions every findings-driven module performs the same way.
/// Always wraps `TrashRemover` in `GuardedRemover` (CLAUDE.md rules 3 and 4).
@MainActor
enum FindingsActions {
    enum Outcome: Hashable {
        case info(String)
        case error(String)
    }

    static func makeRemover() -> any Remover {
        GuardedRemover(wrapping: TrashRemover(), protectedPaths: .default)
    }

    /// Removes the model's selected findings, records the manifest on
    /// `appState`, and posts a notification. Returns a message to surface, if any.
    static func clean(_ model: ScanViewModel,
                      mode: RemovalMode,
                      appState: AppState,
                      moduleTitle: String) async -> Outcome? {
        do {
            let manifest = try await model.remove(using: makeRemover(), mode: mode)
            if model.module == .cleanup {
                appState.lastCleanupManifest = manifest
            }
            appState.lastRemovalManifests[model.module] = manifest
            appState.post(title: "\(moduleTitle) finished",
                          message: "Reclaimed \(ByteFormatter.string(manifest.bytesReclaimed)).")
            let failed = manifest.records.filter { !$0.succeeded }
            if !failed.isEmpty {
                return .error("\(failed.count) item(s) could not be removed. \(failed.first?.error ?? "")")
            }
            return nil
        } catch {
            return .error(error.localizedDescription)
        }
    }

    /// Restores the model's last removal from the Trash.
    static func undo(_ model: ScanViewModel, appState: AppState) async -> Outcome {
        do {
            let restored = try await model.undoLastRemoval(using: makeRemover())
            let count = restored.filter(\.succeeded).count
            if model.module == .cleanup {
                appState.lastCleanupManifest = nil
            }
            appState.lastRemovalManifests[model.module] = nil
            return .info("Restored \(count) of \(restored.count) items from the Trash. Run a new scan to see them again.")
        } catch {
            return .error(error.localizedDescription)
        }
    }
}

/// Segmented tab strip shown under the toolbar in multi-tab modules.
struct ModuleTabBar<Tab: Hashable & Identifiable & CaseIterable>: View where Tab.AllCases: RandomAccessCollection {
    @Binding var selection: Tab
    let title: (Tab) -> String

    var body: some View {
        HStack {
            Spacer()
            Picker("Section", selection: $selection) {
                ForEach(Array(Tab.allCases)) { tab in
                    Text(title(tab)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.large)
            .fixedSize()
            Spacer()
        }
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}
