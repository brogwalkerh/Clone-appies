import SwiftUI
import CleanerCore
import DesignSystem

/// Home screen: hero ring, five module cards, Assistant recommendations.
/// The combined five-module scan lands in M5; today the primary action runs Cleanup.
struct SmartCareView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    private let moduleItems: [SidebarItem] = [.cleanup, .protection, .performance, .applications, .myClutter]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                hero
                moduleCards
                AssistantPanel(recommendations: recommendations)
            }
            .padding(32)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Smart Care")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            BottomActionBar {
                PrimaryActionButton(primaryTitle, isLoading: appState.cleanup.isScanning) {
                    appState.select(.cleanup)
                    appState.cleanup.context = SettingsStore.scanContext()
                    appState.cleanup.run()
                }
            }
        }
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
                Text("One run checks for junk, threats, slowdowns, outdated apps, and clutter, then shows a single result you can act on.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    StatPill(systemImage: "trash",
                             value: cleanupSummary.map { ByteFormatter.string($0.totalBytes) } ?? "—",
                             caption: "Junk found",
                             tint: ModuleTint.cleanup.color(for: scheme, contrast: contrast))
                    StatPill(systemImage: "shield",
                             value: "—",
                             caption: "Threats",
                             tint: ModuleTint.protection.color(for: scheme, contrast: contrast))
                    StatPill(systemImage: "arrow.up.circle",
                             value: "—",
                             caption: "Updates",
                             tint: ModuleTint.applications.color(for: scheme, contrast: contrast))
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var cleanupSummary: ScanSummary? {
        appState.lastScanSummaries[.cleanup]
    }

    private var ringPhase: ScanRing.Phase {
        if appState.cleanup.isScanning {
            return .scanning(fraction: appState.cleanup.progress)
        }
        if let summary = cleanupSummary {
            let parts = ByteText.components(summary.totalBytes)
            return .result(value: parts.value, unit: parts.unit, caption: "can be freed")
        }
        return .idle
    }

    private var primaryTitle: String {
        if appState.cleanup.isScanning { return "Scanning…" }
        return cleanupSummary == nil ? "Run" : "Run Again"
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
        switch item {
        case .cleanup:
            if appState.cleanup.isScanning { return .scanning }
            if let summary = cleanupSummary {
                return summary.totalFindings == 0
                    ? .clean
                    : .result("\(ByteFormatter.string(summary.totalBytes)) to clean")
            }
            return .notScanned
        default:
            return .comingSoon(item.pendingMilestone ?? "later")
        }
    }

    // MARK: Assistant (rule-based, PLAN.md §3.1)

    private var recommendations: [Recommendation] {
        var list: [Recommendation] = []
        if appState.permissions.fullDiskAccess == .denied {
            list.append(Recommendation(
                systemImage: "lock.shield",
                title: "Grant Full Disk Access",
                detail: "Cleanup can only see part of your Mac until Full Disk Access is on.",
                action: .openSettings(.fullDiskAccess)))
        }
        if let summary = cleanupSummary, summary.totalBytes > 0, appState.lastCleanupManifest == nil {
            list.append(Recommendation(
                systemImage: "trash",
                title: "Review \(ByteFormatter.string(summary.totalBytes)) of junk",
                detail: "Cleanup found files you can safely remove.",
                action: .navigate(.cleanup)))
        }
        if cleanupSummary == nil, !appState.cleanup.isScanning {
            list.append(Recommendation(
                systemImage: "sparkles",
                title: "Run your first scan",
                detail: "A Cleanup scan of a typical home folder takes under a minute.",
                action: .navigate(.cleanup)))
        }
        list.append(Recommendation(
            systemImage: "circle.hexagongrid",
            title: "See what takes up space",
            detail: "Space Lens maps your disk as bubbles sized by content.",
            action: .navigate(.spaceLens)))
        list.append(Recommendation(
            systemImage: "clock.arrow.circlepath",
            title: "Schedule regular scans",
            detail: "Scheduled scans and more Assistant rules arrive in M5.",
            action: .none))
        return list
    }
}

// MARK: - Module card

struct ModuleCard: View {
    enum Status: Hashable {
        case notScanned
        case scanning
        case clean
        case result(String)
        case comingSoon(String)

        var text: String {
            switch self {
            case .notScanned: return "Not scanned yet"
            case .scanning: return "Scanning…"
            case .clean: return "Nothing to clean"
            case .result(let text): return text
            case .comingSoon(let milestone): return "Coming in \(milestone)"
            }
        }

        var systemImage: String {
            switch self {
            case .notScanned: return "circle.dashed"
            case .scanning: return "arrow.triangle.2.circlepath"
            case .clean: return "checkmark.circle.fill"
            case .result: return "exclamationmark.circle.fill"
            case .comingSoon: return "hammer"
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

struct Recommendation: Identifiable, Hashable {
    enum Action: Hashable {
        case none
        case navigate(SidebarItem)
        case openSettings(PermissionKind)
    }

    let id = UUID()
    let systemImage: String
    let title: String
    let detail: String
    let action: Action
}

struct AssistantPanel: View {
    @Environment(AppState.self) private var appState
    let recommendations: [Recommendation]

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                Label("Assistant", systemImage: "lightbulb")
                    .font(.headline)
                if recommendations.isEmpty {
                    Text("No recommendations right now.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(recommendations) { recommendation in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: recommendation.systemImage)
                                .frame(width: 22)
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(recommendation.title).font(.subheadline.weight(.semibold))
                                Text(recommendation.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            actionButton(for: recommendation.action)
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
    private func actionButton(for action: Recommendation.Action) -> some View {
        switch action {
        case .none:
            EmptyView()
        case .navigate(let item):
            Button("Open") { appState.select(item) }
                .buttonStyle(.glass)
                .controlSize(.small)
        case .openSettings(let kind):
            Button("Open System Settings") { PermissionChecker.openSystemSettings(for: kind) }
                .buttonStyle(.glass)
                .controlSize(.small)
        }
    }
}

#Preview {
    SmartCareView()
        .environment(AppState())
        .frame(width: 1000, height: 800)
}
