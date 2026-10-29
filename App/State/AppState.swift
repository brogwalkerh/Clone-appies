import Foundation
import Observation
import CleanerCore
import CleanupModule
import ClutterModule
import ApplicationsModule
import PerformanceModule
import ProtectionModule
import SmartCareModule
import UIKitBridge

/// An in-app message shown in the toolbar bell popover (Notification Center, PLAN.md §3.12).
/// Persisted through `InboxStore`, shared with the menu bar agent (ADR 0007).
struct AppNotification: Identifiable, Hashable, Sendable {
    let id: UUID
    let title: String
    let message: String
    let date: Date
    var isRead: Bool
    /// A `maccleaner://` URL the notification opens.
    let link: String?

    init(id: UUID = UUID(), title: String, message: String, date: Date = .now, isRead: Bool = false,
         link: String? = nil) {
        self.id = id
        self.title = title
        self.message = message
        self.date = date
        self.isRead = isRead
        self.link = link
    }

    init(_ message: InboxMessage) {
        self.init(id: message.id, title: message.title, message: message.body, date: message.date,
                  isRead: message.isRead, link: message.link)
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

    /// Smart Care's combined scan and single Run (PLAN.md §3.1).
    let smartCare: SmartCareModel

    /// My Tools action sets and scheduled scans (PLAN.md §3.12).
    let automation: AutomationState

    /// Notification Center storage, shared with the menu bar agent.
    @ObservationIgnored private let inbox: InboxStore

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
        smartCare = SmartCareModel()
        automation = AutomationState()
        inbox = ActivityCenter.shared.storage.inbox
        smartCare.appState = self
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
        if let scannerID, let only = CleanupScanners.all().first(where: { type(of: $0).id == scannerID }) {
            cleanup.replaceScanners([only])
            cleanupScannersRestricted = true
        } else {
            restoreFullCleanupScanners()
        }
        cleanup.context = SettingsStore.scanContext()
        cleanup.run()
    }

    /// Lifts a deep link's single-scanner restriction so the next Cleanup run is complete.
    func restoreFullCleanupScanners() {
        guard cleanupScannersRestricted else { return }
        cleanup.replaceScanners(CleanupScanners.all())
        cleanupScannersRestricted = false
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
        post(InboxMessage(title: title, body: message))
    }

    /// Shows the message at once and stores it for the next launch.
    func post(_ message: InboxMessage) {
        notifications.insert(AppNotification(message), at: 0)
        if notifications.count > 50 {
            notifications.removeLast(notifications.count - 50)
        }
        let inbox = self.inbox
        Task { await inbox.post(message) }
    }

    func markAllRead() {
        for index in notifications.indices {
            notifications[index].isRead = true
        }
        let inbox = self.inbox
        Task { await inbox.markRead(nil) }
    }

    func clearNotifications() {
        notifications.removeAll()
        let inbox = self.inbox
        Task { await inbox.removeAll() }
    }

    /// Re-reads the inbox: picks up what the menu bar agent posted while the window was closed.
    func reloadNotifications() async {
        notifications = await inbox.messages().map(AppNotification.init)
    }

    /// Notifications, activity history, action sets and schedules live in files
    /// the agent and the CLI also write (ADR 0007); re-read them on activation.
    func reloadSharedState() async {
        await reloadNotifications()
        await ActivityCenter.shared.reload()
        automation.reload()
    }

    // MARK: Scheduled runs

    /// Runs one schedule's target. The menu bar agent opens
    /// `maccleaner://schedule?id=` when a schedule comes due and has already
    /// recorded the run, so a slow scan never fires twice.
    func runSchedule(id: UUID) async {
        automation.reload()
        guard let schedule = automation.schedules.first(where: { $0.id == id }) else { return }
        switch schedule.target {
        case .smartCareScan:
            await smartCare.scan()
            notifyScheduled(title: "Scheduled Smart Care scan", body: smartCare.resultSummary(),
                            link: "maccleaner://smart-care")
        case .moduleScan(let module):
            let summary = await scan(module)
            let found = summary.map { "\($0.totalFindings) items, \(ByteFormatter.string($0.totalBytes))" } ?? "no results"
            notifyScheduled(title: "Scheduled \(module.displayName) scan", body: "Found \(found).",
                            link: "maccleaner://smart-care")
        case .actionSet(let setID):
            guard let set = automation.actionSet(withID: setID) else {
                notifyScheduled(title: "Scheduled action set missing",
                                body: "The action set for a schedule was deleted. Edit the schedule in Settings › Scheduler.",
                                link: nil)
                return
            }
            if let report = await automation.run(set) {
                let failed = report.results.filter { !$0.succeeded }.count
                let tail = failed == 0 ? "" : " \(failed) step(s) failed."
                notifyScheduled(title: "Ran \(set.name)",
                                body: "Reclaimed \(ByteFormatter.string(report.bytesReclaimed)).\(tail)",
                                link: "maccleaner://smart-care")
            }
        }
    }

    /// Scans one module to completion and records its summary.
    @discardableResult
    func scan(_ module: ModuleID) async -> ScanSummary? {
        let context = SettingsStore.scanContext()
        switch module {
        case .protection:
            await malware.runToCompletion()
            if let summary = malware.summary { record(summary: summary, for: .protection) }
            return malware.summary
        case .cleanup:
            restoreFullCleanupScanners()
            cleanup.context = context
            await cleanup.runToCompletion()
            if let summary = cleanup.summary { record(summary: summary, for: .cleanup) }
            return cleanup.summary
        case .performance, .applications, .clutter:
            let model = module == .performance ? performanceModel : (module == .applications ? applicationsModel : clutterModel)
            model.context = context
            await model.runToCompletion()
            if let summary = model.summary { record(summary: summary, for: module) }
            return model.summary
        }
    }

    private func notifyScheduled(title: String, body: String, link: String?) {
        post(InboxMessage(kind: .scanResult, title: title, body: body, link: link))
        UserNotifier.post(title: title, body: body, link: link)
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
