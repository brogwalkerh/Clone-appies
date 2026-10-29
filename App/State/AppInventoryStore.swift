import Foundation
import Observation
import CleanerCore
import ApplicationsModule
import UIKitBridge
import SmartCareModule

/// Installed apps, their leftovers and available updates, for the Applications
/// module's Uninstaller and Updater tabs and for `UninstallAppIntent`.
///
/// Discovery and leftover resolution run through the Foundation-only
/// `ApplicationsModule`; update sources are Sparkle (module), App Store and
/// Homebrew (UIKitBridge). Uninstall goes through the same `Remover` path as
/// every other removal (trash first, manifest for undo) and refuses system apps.
@MainActor
@Observable
final class AppInventoryStore {
    enum DiscoveryState: Hashable, Sendable {
        case idle
        case discovering
        case ready
        case failed(String)
    }

    enum UpdateState: Hashable, Sendable {
        case idle
        case checking
        case checked(Date)
    }

    enum UninstallError: LocalizedError {
        case systemApp(String)
        case bundleProtected(String)

        var errorDescription: String? {
            switch self {
            case .systemApp(let name):
                return "\(name) is part of macOS and cannot be uninstalled."
            case .bundleProtected(let name):
                return "\(name) lives in a protected location and was left alone."
            }
        }
    }

    // MARK: State

    private(set) var apps: [InstalledApp] = []
    private(set) var discovery: DiscoveryState = .idle

    /// Bundle URL of the app selected in the Uninstaller list.
    var selectedAppID: InstalledApp.ID?

    /// Resolved leftovers per bundle URL, filled lazily by `leftovers(for:)`.
    private(set) var leftoversByApp: [URL: [Finding]] = [:]
    private(set) var resolvingLeftovers: Set<URL> = []

    private(set) var updates: [AvailableUpdate] = []
    private(set) var updateState: UpdateState = .idle

    private(set) var isUninstalling = false
    private(set) var lastUninstallManifest: RemovalManifest?
    private(set) var lastError: String?

    var selectedApp: InstalledApp? {
        guard let selectedAppID else { return nil }
        return apps.first { $0.id == selectedAppID }
    }

    var isDiscovering: Bool { discovery == .discovering }
    var isCheckingUpdates: Bool { updateState == .checking }

    /// Apps the Uninstaller may offer to remove (everything but `.system`).
    var removableApps: [InstalledApp] {
        apps.filter { !$0.isSystem }
    }

    // MARK: Dependencies

    private let fileSystem: any FileSystem
    private let inventory: AppInventory
    private let resolver: LeftoverResolver
    private let updateChecker: UpdateChecker

    init(fileSystem: any FileSystem = LocalFileSystem(),
         updateSources: [any UpdateSource] = [SparkleUpdateSource(),
                                              AppStoreUpdateSource(),
                                              HomebrewUpdateSource()]) {
        self.fileSystem = fileSystem
        self.inventory = AppInventory(fileSystem: fileSystem)
        self.resolver = LeftoverResolver(fileSystem: fileSystem)
        self.updateChecker = UpdateChecker(sources: updateSources)
    }

    // MARK: Discovery

    /// Re-discovers installed apps. Keeps the current selection when the app still exists.
    func refresh() async {
        guard discovery != .discovering else { return }
        discovery = .discovering
        lastError = nil
        let inventory = self.inventory
        let home = fileSystem.homeDirectory()
        do {
            let discovered = try await inventory.discover(home: home)
            apps = discovered.sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            let known = Set(apps.map(\.id))
            leftoversByApp = leftoversByApp.filter { known.contains($0.key) }
            if let selectedAppID, !known.contains(selectedAppID) {
                self.selectedAppID = nil
            }
            updates.removeAll { !known.contains($0.app.id) }
            discovery = .ready
            AppIconProvider.clearCache()
        } catch {
            discovery = .failed(error.localizedDescription)
            lastError = error.localizedDescription
        }
    }

    /// Discovers apps once; later calls are free.
    func refreshIfNeeded() async {
        guard discovery == .idle else { return }
        await refresh()
    }

    func app(withID id: InstalledApp.ID) -> InstalledApp? {
        apps.first { $0.id == id }
    }

    /// Lookup by standardized bundle path, tolerant of trailing-slash and
    /// percent-encoding differences (used by `InstalledAppEntity`).
    func app(withPath path: String) -> InstalledApp? {
        let wanted = AppInventoryStore.normalizedPath(URL(fileURLWithPath: path))
        return apps.first { AppInventoryStore.normalizedPath($0.bundleURL) == wanted }
    }

    nonisolated static func normalizedPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    // MARK: Leftovers

    /// Leftovers already resolved for `app`, or `nil` if not looked up yet.
    func cachedLeftovers(for app: InstalledApp) -> [Finding]? {
        leftoversByApp[app.id]
    }

    /// Resolves (and caches) the support files, caches, containers and launch
    /// agents belonging to `app`.
    func leftovers(for app: InstalledApp) async -> [Finding] {
        if let cached = leftoversByApp[app.id] {
            return cached
        }
        resolvingLeftovers.insert(app.id)
        defer { resolvingLeftovers.remove(app.id) }
        let resolver = self.resolver
        let home = fileSystem.homeDirectory()
        let found = await resolver.leftovers(for: app, home: home)
        let sorted = found.sorted { $0.sizeBytes > $1.sizeBytes }
        leftoversByApp[app.id] = sorted
        return sorted
    }

    // MARK: Updates

    /// Asks every update source about every discovered app.
    func checkForUpdates() async {
        guard updateState != .checking else { return }
        if discovery == .idle {
            await refresh()
        }
        updateState = .checking
        let checker = updateChecker
        let snapshot = apps
        let found = await checker.check(snapshot)
        updates = found.sorted { lhs, rhs in
            lhs.app.name.localizedCaseInsensitiveCompare(rhs.app.name) == .orderedAscending
        }
        updateState = .checked(.now)
    }

    // MARK: Uninstall

    /// Moves the bundle and the given leftovers (default: every resolved leftover)
    /// to the Trash through `remover`, which must be the app's `GuardedRemover`.
    /// System apps are refused before anything is touched.
    @discardableResult
    func uninstall(_ app: InstalledApp,
                   leftovers: [Finding]? = nil,
                   using remover: any Remover,
                   mode: RemovalMode = .trash) async throws -> RemovalManifest {
        guard !app.isSystem else {
            throw UninstallError.systemApp(app.name)
        }
        guard !ProtectedPaths.default.isProtected(app.bundleURL) else {
            throw UninstallError.bundleProtected(app.name)
        }

        let extras: [Finding]
        if let leftovers {
            extras = leftovers
        } else {
            extras = await self.leftovers(for: app)
        }
        let targets = [AppInventoryStore.bundleFinding(for: app)] + extras

        isUninstalling = true
        lastError = nil
        defer { isUninstalling = false }

        let manifest: RemovalManifest
        do {
            manifest = try await remover.remove(targets, mode: mode, progress: nil)
        } catch {
            lastError = error.localizedDescription
            throw error
        }

        lastUninstallManifest = manifest
        ActivityCenter.shared.record(.removal(manifest, module: .applications))
        let removed = Set(manifest.records.lazy.filter(\.succeeded).map(\.finding.path))
        if removed.contains(app.bundleURL) {
            apps.removeAll { $0.id == app.id }
            leftoversByApp[app.id] = nil
            updates.removeAll { $0.app.id == app.id }
            if selectedAppID == app.id {
                selectedAppID = nil
            }
        } else if var remaining = leftoversByApp[app.id] {
            remaining.removeAll { removed.contains($0.path) }
            leftoversByApp[app.id] = remaining
        }
        return manifest
    }

    /// Best-effort restore of the last uninstall from the Trash.
    @discardableResult
    func undoLastUninstall(using remover: any Remover) async throws -> [RemovalRecord] {
        guard let manifest = lastUninstallManifest else { return [] }
        isUninstalling = true
        defer { isUninstalling = false }
        do {
            let restored = try await remover.undo(manifest)
            lastUninstallManifest = nil
            if restored.contains(where: \.succeeded) {
                discovery = .idle
            }
            return restored
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    /// The app bundle itself as a `Finding`, so it flows through `Remover`
    /// and lands in the manifest next to its leftovers.
    static func bundleFinding(for app: InstalledApp) -> Finding {
        Finding(path: app.bundleURL,
                sizeBytes: app.sizeBytes,
                category: FindingCategory(id: "applications.bundle",
                                          displayName: "Application",
                                          module: .applications),
                scannerID: "applications.uninstaller",
                risk: .caution,
                detail: app.version.map { "\(app.name) \($0)" } ?? app.name,
                modifiedAt: app.lastOpened,
                isDirectory: true)
    }
}
