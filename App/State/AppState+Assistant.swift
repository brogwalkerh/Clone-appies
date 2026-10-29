import Foundation
import CleanerCore
import SmartCareModule

extension AppState {
    /// Facts for the rule-based Assistant (PLAN.md §3.1). Anything the app
    /// has not measured yet stays nil, and the rules that need it stay quiet.
    func assistantSnapshot(now: Date = .now) -> AssistantSnapshot {
        let stats = ActivityCenter.shared.stats
        var snapshot = AssistantSnapshot(now: now)
        snapshot.lastScan = stats.lastScan
        snapshot.summaries = lastScanSummaries
        snapshot.lastSmartCare = smartCare.lastScanDate
        snapshot.lastRemoval = stats.lastRemoval
        snapshot.lastMaintenance = stats.lastMaintenance
        snapshot.trashBytes = lastScanSummaries[.cleanup]?.byCategory["cleanup.trash"]

        let home = FileManager.default.homeDirectoryForCurrentUser
        if let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                           .volumeTotalCapacityKey]) {
            snapshot.diskFreeBytes = values.volumeAvailableCapacityForImportantUsage
            snapshot.diskCapacityBytes = values.volumeTotalCapacity.map(Int64.init)
        }

        switch permissions.fullDiskAccess {
        case .granted: snapshot.hasFullDiskAccess = true
        case .denied: snapshot.hasFullDiskAccess = false
        case .unknown, .notDetermined: snapshot.hasFullDiskAccess = nil
        }
        snapshot.helperInstalled = HelperClient.shared.isInstalled
        if case .checked = appInventory.updateState {
            snapshot.updatesAvailable = appInventory.updates.count
        }
        snapshot.openThreats = malware.threats.count
        snapshot.signaturesUpdated = SettingsStore.signaturesUpdatedAt()
        snapshot.hasEnabledSchedule = automation.schedules.contains { $0.isEnabled }
        return snapshot
    }

    /// Rule id -> when the user dismissed it.
    func dismissedRecommendations() -> [String: Date] {
        automation.storage.dismissedRecommendations.load() ?? [:]
    }

    func dismissRecommendation(_ id: String) {
        var dismissed = dismissedRecommendations()
        dismissed[id] = .now
        try? automation.storage.dismissedRecommendations.save(dismissed)
    }
}
