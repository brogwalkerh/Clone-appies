import Foundation
import Observation
import CleanerCore
import CleanupModule
import ClutterModule
import ApplicationsModule
import PerformanceModule
import ProtectionModule
import UIKitBridge

/// An in-app message shown in the toolbar bell popover (Notification Center, PLAN.md §3.12).
struct AppNotification: Identifiable, Hashable, Sendable {
    let id: UUID
    let title: String
    let message: String
    let date: Date
    var isRead: Bool

    init(id: UUID = UUID(), title: String, message: String, date: Date = .now, isRead: Bool = false) {
        self.id = id
        self.title = title
        self.message = message
        self.date = date
        self.isRead = isRead
    }
}

/// Window-independent app state: selection, pins, notifications, permissions,
/// last scan summaries, and the long-lived scan view models so results survive
/// switching between sidebar items.
@MainActor
@Observable
final class AppState {
    // MARK: Navigation

    var selection: SidebarItem? = .smartCare

    /// "My Tools" pins, in display order.
    private(set) var pinnedTools: [SidebarItem]

    // MARK: Notification Center

    private(set) var notifications: [AppNotification] = []

    var unreadCount: Int {
        notifications.lazy.filter { !$0.isRead }.count
    }

    // MARK: Permissions and onboarding

    private(set) var permissions: PermissionSnapshot = .unknown
    private(set) var hasCompletedOnboarding: Bool

    /// Set when a module needs the privileged helper (Performance's "Install helper"
    /// link, `maccleaner://performance?task=`). `RootView` shows the onboarding
    /// helper step as a sheet while this is true.
    var helperInstallRequested = false

    // MARK: Scan results

    /// Latest `ScanSummary` per module, used by Smart Care cards and the hero ring.
    var lastScanSummaries: [ModuleID: ScanSummary] = [:]

    /// The most recent cleanup manifest, kept for "Undo last cleanup".
    var lastCleanupManifest: RemovalManifest?

    /// Latest removal manifest per module (Applications, My Clutter, …) for Smart Care's summary.
    var lastRemovalManifests: [ModuleID: RemovalManifest] = [:]

    /// Cleanup module wiring (PLAN.md §5 scan engine). Built once so a running
    /// scan is not torn down when the user switches sidebar items.
    let cleanup: ScanViewModel

    /// Applications › Leftovers and Installers (orphaned leftovers + stray installers).
    let applicationsModel: ScanViewModel

    /// My Clutter: Large & Old, Duplicates, Similar Images (Vision), Downloads.
    /// Scanners are rebuilt via `replaceScanners` when the Large & Old sliders move.
    let clutterModel: ScanViewModel

    /// Performance's scan-driven findings (broken login items via `PerformanceScanners.all()`).
    let performanceModel: ScanViewModel

    /// Performance › Maintenance selection, run state and streamed results.
    let maintenance: MaintenanceState

    /// Protection › Malware: signature database, scope, threats, quarantine (PLAN.md §3.3).
    let malware: MalwareScanModel

    /// Protection › Privacy: browser history/cookies/caches, recent items, chat caches (`PrivacyScanners.all()`).
    let privacyModel: ScanViewModel

    /// Installed apps, leftovers and available updates for Applications › Uninstaller / Updater.
    let appInventory: AppInventoryStore

    /// True while `cleanup` runs a subset of `CleanupScanners.all()` (deep link
    /// `maccleaner://cleanup?scanner=`); the next plain scan restores the full set.
    private var cleanupScannersRestricted = false

    // MARK: Init

    init() {
        let defaults = SettingsStore.defaults
        hasCompletedOnboarding = defaults.bool(forKey: SettingsStore.Key.hasCompletedOnboarding)
        let rawPins = defaults.stringArray(forKey: SettingsStore.Key.pinnedTools) ?? []
        pinnedTools = rawPins.compactMap(SidebarItem.init(rawValue:))
        cleanup = ScanViewModel(
            module: .cleanup,
            scanners: CleanupScanners.all(),
            context: SettingsStore.scanContext()
        )
        applicationsModel = ScanViewModel(
            module: .applications,
            scanners: ApplicationsScanners.all(),
            context: SettingsStore.scanContext()
        )
        clutterModel = ScanViewModel(
            module: .clutter,
            scanners: AppState.makeClutterScanners(),
            context: SettingsStore.scanContext()
        )
        performanceModel = ScanViewModel(
            module: .performance,
            scanners: PerformanceScanners.all(),
            context: SettingsStore.scanContext()
        )
        maintenance = MaintenanceState()
        malware = MalwareScanModel()
        privacyModel = ScanViewModel(
            module: .protection,
            scanners: PrivacyScanners.all(),
            context: SettingsStore.scanContext()
        )
        appInventory = AppInventoryStore()
    }

    /// `ClutterScanners.all` with Vision feature prints, with the Large & Old
    /// scanner swapped for one built from the thresholds stored in Settings.
    static func makeClutterScanners() -> [any CleanerScanner] {
        let minSize = Int64(SettingsStore.largeOldMinSizeMB() * 1_000_000)
        let minAge = SettingsStore.largeOldMinAgeDays() * 86_400
        return ClutterScanners.all(imageFeatures: VisionImageFeatureProvider()).map { scanner -> any CleanerScanner in
            if scanner is LargeOldFilesScanner {
                return LargeOldFilesScanner(minSizeBytes: minSize, minAge: minAge)
            }
            return scanner
        }
    }

    // MARK: Navigation actions

    func select(_ item: SidebarItem) {
        selection = item
    }

    /// Routes a `maccleaner://` URL (see `DeepLinkRouter`). Returns `false` for foreign URLs.
    @discardableResult
    func open(_ url: URL) -> Bool {
        DeepLinkRouter(appState: self).open(url)
    }

    /// Asks `RootView` to present the onboarding helper step.
    func requestHelperInstall() {
        helperInstallRequested = true
    }

    /// Starts a Cleanup scan, optionally restricted to one scanner id (deep link).
    /// An unknown id falls back to the full scan. A previous restriction is lifted
    /// on the next unrestricted call so the Cleanup screen's "Scan" stays complete.
    func runCleanup(restrictedTo scannerID: String? = nil) {
        let all = CleanupScanners.all()
        if let scannerID, let only = all.first(where: { type(of: $0).id == scannerID }) {
            cleanup.replaceScanners([only])
            cleanupScannersRestricted = true
        } else if cleanupScannersRestricted {
            cleanup.replaceScanners(all)
            cleanupScannersRestricted = false
        }
        cleanup.context = SettingsStore.scanContext()
        cleanup.run()
    }

    /// Starts a malware scan, optionally switching scope first (deep link
    /// `maccleaner://protection?scope=`). `ProtectionView` consumes `pendingFocus`
    /// to show the Malware tab. A scan already running keeps its scope.
    func runMalwareScan(scope: ScanScope? = nil) {
        if let scope, !malware.isScanning {
            malware.scope = scope
        }
        malware.pendingFocus = true
        malware.run()
    }

    func isPinned(_ item: SidebarItem) -> Bool {
        pinnedTools.contains(item)
    }

    func togglePin(_ item: SidebarItem) {
        guard item.isPinnable else { return }
        if let index = pinnedTools.firstIndex(of: item) {
            pinnedTools.remove(at: index)
        } else {
            pinnedTools.append(item)
        }
        SettingsStore.defaults.set(pinnedTools.map(\.rawValue), forKey: SettingsStore.Key.pinnedTools)
    }

    func movePins(fromOffsets source: IndexSet, toOffset destination: Int) {
        pinnedTools.move(fromOffsets: source, toOffset: destination)
        SettingsStore.defaults.set(pinnedTools.map(\.rawValue), forKey: SettingsStore.Key.pinnedTools)
    }

    // MARK: Notification actions

    func post(title: String, message: String) {
        notifications.insert(AppNotification(title: title, message: message), at: 0)
        if notifications.count > 50 {
            notifications.removeLast(notifications.count - 50)
        }
    }

    func markAllRead() {
        for index in notifications.indices {
            notifications[index].isRead = true
        }
    }

    func clearNotifications() {
        notifications.removeAll()
    }

    // MARK: Permissions and onboarding actions

    /// Re-checks every permission. Called on launch and when the window regains focus.
    func refreshPermissions() async {
        permissions = await PermissionChecker.snapshot()
    }

    func completeOnboarding() {
        hasCompletedOnboarding = true
        SettingsStore.defaults.set(true, forKey: SettingsStore.Key.hasCompletedOnboarding)
    }

    func resetOnboarding() {
        hasCompletedOnboarding = false
        SettingsStore.defaults.set(false, forKey: SettingsStore.Key.hasCompletedOnboarding)
    }

    // MARK: Scan bookkeeping

    func record(summary: ScanSummary, for module: ModuleID) {
        lastScanSummaries[module] = summary
    }
}
