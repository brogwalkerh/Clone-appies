import AppKit
import ServiceManagement
import SwiftUI
import CleanerCore
import DesignSystem
import HelperProtocol
import PerformanceModule
import UIKitBridge

/// Discovers launchd items and toggles them: user agents with `launchctl`
/// (`LaunchctlService`), system agents / daemons through the privileged helper.
/// Apple items and login-item apps are read-only; the latter are managed in
/// System Settings › Login Items.
@MainActor
@Observable
final class BackgroundItemsStore {
    private(set) var items: [BackgroundItem] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var loadError: String?
    /// Items whose enabled state is being changed.
    private(set) var busyIDs: Set<URL> = []
    /// Local override while launchd's answer is stale (or `enabledState` is nil).
    private var enabledOverrides: [URL: Bool] = [:]
    private(set) var isRemoving = false

    private let fileSystem: any FileSystem
    private let inventory: BackgroundItemsInventory
    private let launchctl = LaunchctlService()

    init(fileSystem: any FileSystem = LocalFileSystem()) {
        self.fileSystem = fileSystem
        self.inventory = BackgroundItemsInventory(fileSystem: fileSystem,
                                                  enabledStateProvider: LaunchctlStateProvider())
    }

    // MARK: Loading

    func refreshIfNeeded() async {
        guard !hasLoaded, !isLoading else { return }
        await refresh()
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let home = fileSystem.homeDirectory()
            let discovered = try await inventory.discover(home: home)
            items = discovered.sorted { lhs, rhs in
                if lhs.isBroken != rhs.isBroken { return lhs.isBroken }
                return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
            }
            enabledOverrides = [:]
            hasLoaded = true
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: Grouping

    static let domainOrder: [BackgroundItemDomain] = [.userAgent, .loginItemApp, .systemAgent, .systemDaemon]

    func items(in domain: BackgroundItemDomain) -> [BackgroundItem] {
        items.filter { $0.domain == domain }
    }

    static func title(for domain: BackgroundItemDomain) -> String {
        switch domain {
        case .userAgent: return "Your Launch Agents"
        case .loginItemApp: return "Login Item Apps"
        case .systemAgent: return "System Launch Agents"
        case .systemDaemon: return "System Launch Daemons"
        }
    }

    static func footer(for domain: BackgroundItemDomain) -> String? {
        switch domain {
        case .userAgent: return "~/Library/LaunchAgents. Toggling loads or unloads the agent with launchctl."
        case .loginItemApp: return "Apps that open at login. Change these in System Settings › General › Login Items."
        case .systemAgent, .systemDaemon: return "/Library. Toggling needs the privileged helper; Apple's own items are never changed."
        }
    }

    // MARK: Enabled state

    func isEnabled(_ item: BackgroundItem) -> Bool {
        enabledOverrides[item.id] ?? item.enabledState ?? true
    }

    func canToggle(_ item: BackgroundItem, helperAvailable: Bool) -> Bool {
        guard !item.isApple, !item.isBroken, !busyIDs.contains(item.id) else { return false }
        switch item.domain {
        case .userAgent: return true
        case .systemAgent, .systemDaemon: return helperAvailable
        case .loginItemApp: return false
        }
    }

    /// Why a toggle is disabled, for the row's help text.
    func toggleHint(_ item: BackgroundItem, helperAvailable: Bool) -> String? {
        if item.isApple { return "Part of macOS; read-only." }
        if item.isBroken { return "The program no longer exists. Remove the item instead." }
        switch item.domain {
        case .userAgent: return nil
        case .loginItemApp: return "Manage login item apps in System Settings."
        case .systemAgent, .systemDaemon: return helperAvailable ? nil : "Needs the privileged helper."
        }
    }

    func setEnabled(_ enabled: Bool, for item: BackgroundItem) async throws {
        guard !busyIDs.contains(item.id) else { return }
        busyIDs.insert(item.id)
        defer { busyIDs.remove(item.id) }
        switch item.domain {
        case .userAgent:
            try await launchctl.setUserAgentEnabled(plistURL: item.plistURL, enabled: enabled)
        case .systemAgent, .systemDaemon:
            let response = try await HelperClient.shared.perform(.setLaunchDaemonEnabled(label: item.label, enabled: enabled))
            guard response.succeeded else {
                throw ToggleError.helperRefused(response.message)
            }
        case .loginItemApp:
            throw ToggleError.readOnly
        }
        enabledOverrides[item.id] = enabled
    }

    enum ToggleError: LocalizedError {
        case readOnly
        case helperRefused(String)

        var errorDescription: String? {
            switch self {
            case .readOnly: return "This item is managed by macOS. Change it in System Settings › Login Items."
            case .helperRefused(let message): return message
            }
        }
    }

    // MARK: Broken items

    static let brokenCategory = FindingCategory(id: "performance.brokenLoginItems",
                                                displayName: "Broken Login Items",
                                                module: .performance)

    /// Broken, non-Apple items in the user's own LaunchAgents folder as findings.
    /// System-domain plists need root to move and have no helper operation
    /// (CLAUDE.md rule 5), so they are listed but not offered for removal.
    var removableBrokenFindings: [Finding] {
        items
            .filter { $0.isBroken && !$0.isApple && $0.domain == .userAgent }
            .map { item in
                let size = (try? fileSystem.attributes(of: item.plistURL))?.sizeBytes ?? 0
                return Finding(path: item.plistURL,
                               sizeBytes: size,
                               category: BackgroundItemsStore.brokenCategory,
                               scannerID: "performance.brokenLoginItems",
                               risk: .safe,
                               detail: "Program missing: \(item.program ?? "unknown")",
                               isDirectory: false)
            }
    }

    /// Trash-first removal through the standard `Remover` (CLAUDE.md rule 3).
    func removeBrokenItems(using remover: any Remover, mode: RemovalMode) async throws -> RemovalManifest {
        let targets = removableBrokenFindings
        guard !targets.isEmpty else { throw ScanViewModel.RemovalError.nothingSelected }
        isRemoving = true
        defer { isRemoving = false }
        let manifest = try await remover.remove(targets, mode: mode, progress: nil)
        let removed = Set(manifest.records.lazy.filter(\.succeeded).map(\.finding.path))
        items.removeAll { removed.contains($0.plistURL) }
        return manifest
    }

    static func openLoginItemsSettings() {
        // TODO(macOS27): verify the Login Items extension URL still resolves; falls back to SMAppService.
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        } else {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}

// MARK: - Tab

struct BackgroundItemsTab: View {
    let store: BackgroundItemsStore
    let helperAvailable: Bool
    let onInstallHelper: @MainActor () -> Void
    let onError: @MainActor (String) -> Void

    var body: some View {
        if store.isLoading, store.items.isEmpty {
            EmptyState.scanning("Reading launch agents…",
                                message: "~/Library/LaunchAgents, /Library/LaunchAgents, /Library/LaunchDaemons and login item apps.")
        } else if let error = store.loadError, store.items.isEmpty {
            EmptyState(title: "Could Not Read Login Items",
                       message: error,
                       style: .symbol("exclamationmark.triangle"),
                       actionTitle: "Try Again") {
                Task { await store.refresh() }
            }
        } else if store.items.isEmpty {
            EmptyState.nothingFound("No Background Items",
                                    message: "Nothing starts at login besides macOS itself.",
                                    actionTitle: "Refresh") {
                Task { await store.refresh() }
            }
        } else {
            List {
                if !helperAvailable, store.items.contains(where: { $0.domain != .userAgent && $0.domain != .loginItemApp && !$0.isApple }) {
                    HStack(spacing: 10) {
                        Image(systemName: "lock.shield").foregroundStyle(.orange)
                        Text("System agents and daemons can be toggled once the privileged helper is installed.")
                            .font(.callout)
                        Spacer()
                        Button("Install helper") { onInstallHelper() }
                            .buttonStyle(.link)
                    }
                    .padding(.vertical, 4)
                }
                ForEach(BackgroundItemsStore.domainOrder, id: \.self) { domain in
                    let items = store.items(in: domain)
                    if !items.isEmpty {
                        Section {
                            ForEach(items) { item in
                                BackgroundItemRow(item: item,
                                                  isEnabled: store.isEnabled(item),
                                                  canToggle: store.canToggle(item, helperAvailable: helperAvailable),
                                                  hint: store.toggleHint(item, helperAvailable: helperAvailable),
                                                  isBusy: store.busyIDs.contains(item.id)) { enabled in
                                    toggle(item, enabled: enabled)
                                }
                            }
                        } header: {
                            Text("\(BackgroundItemsStore.title(for: domain)) (\(items.count))")
                        } footer: {
                            if let footer = BackgroundItemsStore.footer(for: domain) {
                                Text(footer)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
            .alternatingRowBackgrounds()
        }
    }

    private func toggle(_ item: BackgroundItem, enabled: Bool) {
        Task {
            do {
                try await store.setEnabled(enabled, for: item)
            } catch {
                onError(error.localizedDescription)
            }
        }
    }
}

struct BackgroundItemRow: View {
    let item: BackgroundItem
    let isEnabled: Bool
    let canToggle: Bool
    let hint: String?
    let isBusy: Bool
    let onToggle: @MainActor (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(item.isBroken ? AnyShapeStyle(Color.red) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(item.ownerAppName ?? item.label)
                        .lineLimit(1)
                    if item.ownerAppName != nil {
                        Text(item.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if item.isBroken { PerformanceBadge(text: "Broken", color: .red) }
                    if item.isApple { PerformanceBadge(text: "Apple", color: .gray) }
                    if item.runAtLoad { PerformanceBadge(text: "Run at load", color: .blue) }
                    if item.keepAlive { PerformanceBadge(text: "Keep alive", color: .purple) }
                }
                Text(item.program ?? item.plistURL.path(percentEncoded: false))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if isBusy {
                ProgressView().controlSize(.small)
            }
            Toggle("", isOn: Binding(get: { isEnabled }, set: { onToggle($0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .disabled(!canToggle)
                .help(hint ?? (isEnabled ? "Enabled" : "Disabled"))
                .accessibilityLabel(Text("\(item.label) enabled"))
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.plistURL])
            }
        }
        .help(item.plistURL.path(percentEncoded: false))
    }

    private var symbol: String {
        switch item.domain {
        case .userAgent: return "person.crop.circle"
        case .loginItemApp: return "app"
        case .systemAgent: return "gearshape"
        case .systemDaemon: return "gearshape.2"
        }
    }
}
