import Foundation
import Observation
import CleanerCore
import CleanupModule

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

    // MARK: Scan results

    /// Latest `ScanSummary` per module, used by Smart Care cards and the hero ring.
    var lastScanSummaries: [ModuleID: ScanSummary] = [:]

    /// The most recent cleanup manifest, kept for "Undo last cleanup".
    var lastCleanupManifest: RemovalManifest?

    /// Cleanup module wiring (PLAN.md §5 scan engine). Built once so a running
    /// scan is not torn down when the user switches sidebar items.
    let cleanup: ScanViewModel

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
    }

    // MARK: Navigation actions

    func select(_ item: SidebarItem) {
        selection = item
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
