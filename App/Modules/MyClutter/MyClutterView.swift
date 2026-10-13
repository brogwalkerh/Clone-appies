import AppKit
import ImageIO
import SwiftUI
import CleanerCore
import ClutterModule
import DesignSystem

/// My Clutter module (PLAN.md §3.6): Large & Old · Duplicates · Similar Images · Downloads.
///
/// One `ScanViewModel` (`AppState.clutterModel`) runs all four scanners; each
/// tab filters by category. Large & Old thresholds live in `@AppStorage` and
/// rebuild the scanner list through `ScanViewModel.replaceScanners`, taking
/// effect on the next scan. Duplicates and Similar Images are grouped by the
/// keeper named in each finding's detail line.
struct MyClutterView: View {
    enum Tab: String, CaseIterable, Identifiable, Hashable {
        case largeOld, duplicates, similarImages, downloads

        var id: String { rawValue }

        var title: String {
            switch self {
            case .largeOld: return "Large & Old"
            case .duplicates: return "Duplicates"
            case .similarImages: return "Similar Images"
            case .downloads: return "Downloads"
            }
        }

        var categoryPrefix: String {
            switch self {
            case .largeOld: return "clutter.largeOld"
            case .duplicates: return "clutter.duplicates"
            case .similarImages: return "clutter.similarImages"
            case .downloads: return "clutter.downloads"
            }
        }

        var symbol: String {
            switch self {
            case .largeOld: return "doc.badge.ellipsis"
            case .duplicates: return "doc.on.doc"
            case .similarImages: return "photo.on.rectangle"
            case .downloads: return "arrow.down.circle"
            }
        }

        var intro: String {
            switch self {
            case .largeOld:
                return "Files above the size threshold or untouched for longer than the age threshold in Documents, Desktop, Downloads, Movies, Music and Pictures."
            case .duplicates:
                return "Byte-identical files found by size bucket, partial hash and full SHA-256. The oldest copy is kept; the others are listed."
            case .similarImages:
                return "Near-identical photos clustered with Vision feature prints. The largest image in each group is kept as the best-quality pick."
            case .downloads:
                return "Installers, archives, screenshots and anything older than 90 days in Downloads."
            }
        }
    }

    @Environment(AppState.self) private var appState
    @AppStorage(SettingsStore.Key.removalMode) private var removalModeRaw = RemovalMode.trash.rawValue
    @AppStorage(SettingsStore.Key.largeOldMinSizeMB) private var minSizeMB = SettingsStore.defaultLargeOldMinSizeMB
    @AppStorage(SettingsStore.Key.largeOldMinAgeDays) private var minAgeDays = SettingsStore.defaultLargeOldMinAgeDays

    @State private var tab: Tab = .largeOld
    @State private var expandedGroups: Set<String> = []
    @State private var confirmRemove = false
    @State private var errorMessage: String?
    @State private var infoMessage: String?
    /// True once a slider moved after the last scan, so the list shows a hint.
    @State private var thresholdsChanged = false

    private var model: ScanViewModel { appState.clutterModel }

    var body: some View {
        VStack(spacing: 0) {
            ModuleTabBar(selection: $tab) { $0.title }
            if tab == .largeOld {
                thresholdSliders
            }
            content
        }
        .navigationTitle("My Clutter")
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
            FindingsActionBar(model: model, tint: .clutter,
                              cleanTitle: "Remove",
                              removingTitle: "Removing…",
                              undoTitle: "Undo Last Removal",
                              onScan: { startScan() },
                              onClean: { confirmRemove = true },
                              onUndo: { undo() })
        }
        .onChange(of: minSizeMB) { _, _ in rebuildScanners() }
        .onChange(of: minAgeDays) { _, _ in rebuildScanners() }
        .onChange(of: model.summary) { _, summary in
            if let summary {
                appState.record(summary: summary, for: .clutter)
                if !model.findings.isEmpty {
                    appState.post(title: "My Clutter scan finished",
                                  message: "\(ByteFormatter.string(summary.totalBytes)) in \(summary.totalFindings) items can be reviewed.")
                }
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
            remove()
        }
        .messageAlert("My Clutter", message: $errorMessage)
        .messageAlert("Undo", message: $infoMessage)
    }

    // MARK: Threshold sliders (Large & Old)

    private var thresholdSliders: some View {
        HStack(spacing: 28) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Larger than")
                    Spacer()
                    Text(ByteFormatter.string(Int64(minSizeMB * 1_000_000)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                Slider(value: $minSizeMB, in: 10...5000, step: 10) {
                    Text("Minimum size")
                } minimumValueLabel: {
                    Text("10 MB").font(.caption2)
                } maximumValueLabel: {
                    Text("5 GB").font(.caption2)
                }
                .labelsHidden()
                .accessibilityValue(Text(ByteFormatter.string(Int64(minSizeMB * 1_000_000))))
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Or not opened for")
                    Spacer()
                    Text(ageLabel)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                Slider(value: $minAgeDays, in: 0...720, step: 30) {
                    Text("Minimum age")
                } minimumValueLabel: {
                    Text("Any").font(.caption2)
                } maximumValueLabel: {
                    Text("2 y").font(.caption2)
                }
                .labelsHidden()
                .accessibilityValue(Text(ageLabel))
            }

            if thresholdsChanged, !model.findings.isEmpty {
                Text("Applies on the next scan")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var ageLabel: String {
        let days = Int(minAgeDays)
        if days == 0 { return "Any age" }
        if days % 360 == 0 { return days / 360 == 1 ? "1 year" : "\(days / 360) years" }
        if days % 30 == 0 { return days / 30 == 1 ? "1 month" : "\(days / 30) months" }
        return "\(days) days"
    }

    private func rebuildScanners() {
        thresholdsChanged = true
        model.replaceScanners(AppState.makeClutterScanners())
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        let groups = model.groups(withCategoryPrefix: tab.categoryPrefix)
        switch model.phase {
        case .idle:
            EmptyState(title: "Ready to Scan",
                       message: tab.intro,
                       style: .symbol(tab.symbol))
        case .scanning where groups.isEmpty:
            EmptyState.scanning("Scanning for clutter…", message: model.statusLine, cancel: { model.cancel() })
        case .finished where groups.isEmpty, .cancelled where groups.isEmpty:
            EmptyState.nothingFound(
                model.phase == .cancelled ? "Scan Stopped" : "Nothing Here",
                message: model.phase == .cancelled
                    ? "The scan was stopped before it finished."
                    : "No \(tab.title.lowercased()) items matched. Other tabs may still have results.",
                actionTitle: "Scan Again") {
                startScan()
            }
        default:
            switch tab {
            case .duplicates, .similarImages:
                KeeperGroupList(model: model,
                                findings: model.findings(withCategoryPrefix: tab.categoryPrefix),
                                expandedGroups: $expandedGroups)
            case .largeOld, .downloads:
                FindingsList(model: model, groups: groups, expandedGroups: $expandedGroups)
            }
        }
    }

    private var subtitle: String {
        if model.isScanning { return "Scanning…" }
        let findings = model.findings(withCategoryPrefix: tab.categoryPrefix)
        guard !findings.isEmpty else { return tab.title }
        let bytes = findings.reduce(Int64(0)) { $0 + $1.sizeBytes }
        return "\(ByteFormatter.string(bytes)) in \(findings.count) items • \(ByteFormatter.string(model.selectedBytes)) selected overall"
    }

    // MARK: Actions

    private var removalMode: RemovalMode {
        RemovalMode(rawValue: removalModeRaw) ?? .trash
    }

    private func startScan() {
        expandedGroups = []
        thresholdsChanged = false
        model.context = SettingsStore.scanContext()
        model.run()
    }

    private func remove() {
        let mode = removalMode
        Task {
            if case .error(let message) = await FindingsActions.clean(model, mode: mode, appState: appState, moduleTitle: "My Clutter cleanup") {
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

// MARK: - Keeper groups (Duplicates, Similar Images)

/// A keeper (the copy the scanner decided to keep) and the findings that
/// duplicate or resemble it, parsed from the contract's detail strings
/// "Duplicate of <keeper path>" / "Similar to <keeper>".
struct KeeperGroup: Identifiable, Hashable, Sendable {
    let keeper: String
    let findings: [Finding]

    var id: String { keeper }
    var totalBytes: Int64 { findings.reduce(0) { $0 + $1.sizeBytes } }

    /// A file URL when the keeper string is an absolute path, else `nil`.
    var keeperURL: URL? {
        keeper.hasPrefix("/") ? URL(fileURLWithPath: keeper) : nil
    }

    var keeperName: String {
        keeperURL?.lastPathComponent ?? keeper
    }

    static let detailPrefixes = ["Duplicate of ", "Similar to "]

    /// Groups `findings` by keeper, largest group first. Findings whose detail
    /// does not name a keeper fall into an "Other" group.
    static func groups(from findings: [Finding]) -> [KeeperGroup] {
        var byKeeper: [String: [Finding]] = [:]
        var order: [String] = []
        for finding in findings {
            let keeper = keeperString(from: finding.detail) ?? "Other"
            if byKeeper[keeper] == nil {
                order.append(keeper)
            }
            byKeeper[keeper, default: []].append(finding)
        }
        return order
            .map { KeeperGroup(keeper: $0, findings: byKeeper[$0] ?? []) }
            .sorted { $0.totalBytes > $1.totalBytes }
    }

    static func keeperString(from detail: String?) -> String? {
        guard let detail else { return nil }
        for prefix in detailPrefixes where detail.hasPrefix(prefix) {
            let rest = detail.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? nil : rest
        }
        return nil
    }
}

struct KeeperGroupList: View {
    let model: ScanViewModel
    let findings: [Finding]
    @Binding var expandedGroups: Set<String>

    private var groups: [KeeperGroup] { KeeperGroup.groups(from: findings) }

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
                        KeeperHeader(group: group, state: model.selectionState(for: group.findings)) {
                            model.setSelected(model.selectionState(for: group.findings) != .all, for: group.findings)
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

/// Group header: thumbnail of the keeper (for images), its name, "Keeping this
/// one • n copies", and a tri-state checkbox for the copies.
struct KeeperHeader: View {
    let group: KeeperGroup
    let state: ScanViewModel.GroupSelection
    let toggle: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 10) {
            SelectionCheckbox(state: state, label: group.keeperName, toggle: toggle)

            FileThumbnail(url: group.keeperURL, fallbackSymbol: "doc.on.doc")
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(group.keeperName)
                    .font(.headline)
                    .lineLimit(1)
                Text(group.keeperURL != nil
                     ? "Keeping this one • \(group.findings.count) \(group.findings.count == 1 ? "copy" : "copies")"
                     : "\(group.findings.count) items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(ByteFormatter.string(group.totalBytes))
                .font(.system(.body, design: .rounded).weight(.medium))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .padding(.vertical, 4)
        .contextMenu {
            if let url = group.keeperURL {
                Button("Reveal Keeper in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
        .help(group.keeper)
    }
}

/// Lazily decoded, downscaled thumbnail for image files; a symbol otherwise.
/// Decoding happens on a detached task through ImageIO so a long list of
/// Similar Images never blocks the main actor; the result is a `CGImage`, which
/// (unlike `NSImage`) is Sendable and can cross back to the view.
struct FileThumbnail: View {
    let url: URL?
    let fallbackSymbol: String
    var maxPixelSize: Int = 96

    // TODO(macOS27): relies on `CGImage: Sendable` (macOS 14 SDK onward) to cross
    // back from the detached decode task; if the 27 SDK changes that, return PNG `Data`.
    @State private var image: CGImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.quaternary)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Image(systemName: failed || url == nil ? fallbackSymbol : "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityHidden(true)
        .task(id: url) {
            image = nil
            failed = false
            guard let url, FileThumbnail.isImage(url) else { return }
            let size = maxPixelSize
            let decoded = await Task.detached(priority: .utility) {
                FileThumbnail.thumbnail(at: url, maxPixelSize: size)
            }.value
            if let decoded {
                image = decoded
            } else {
                failed = true
            }
        }
    }

    static func isImage(_ url: URL) -> Bool {
        ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp", "dng"]
            .contains(url.pathExtension.lowercased())
    }

    /// ImageIO downsampling: decodes at most `maxPixelSize` on the long edge,
    /// honouring EXIF orientation, without loading the full bitmap.
    nonisolated static func thumbnail(at url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

#Preview {
    MyClutterView()
        .environment(AppState())
        .frame(width: 1200, height: 800)
}
