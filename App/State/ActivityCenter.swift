import Foundation
import Observation
import CleanerCore
import SmartCareModule

/// The app's side of My Activity (PLAN.md §3.12): appends events to the
/// activity log shared with the CLI (ADR 0007) and keeps the derived stats
/// current for My Activity, Smart Care and the Assistant.
///
/// Models record into `shared` directly (scan finished, removal, undo,
/// quarantine, maintenance) so every path that changes the disk is counted
/// once, whichever screen or intent started it.
@MainActor
@Observable
final class ActivityCenter {
    static let shared = ActivityCenter()

    private(set) var stats: ActivityStats
    /// Newest first, at most `recentLimit`.
    private(set) var recent: [ActivityEvent] = []

    @ObservationIgnored let storage: SmartCareStorage
    @ObservationIgnored private var events: [ActivityEvent] = []
    @ObservationIgnored private let recentLimit = 50

    init(storage: SmartCareStorage = SmartCareStorage(directory: SettingsStore.applicationSupportDirectory())) {
        self.storage = storage
        stats = ActivityStats(events: [], now: .now)
    }

    /// Adds events in memory at once and appends them to the log in the background.
    func record(_ newEvents: [ActivityEvent]) {
        guard !newEvents.isEmpty else { return }
        events.append(contentsOf: newEvents)
        events.sort { $0.date < $1.date }
        recompute()
        let store = storage.activity
        Task.detached(priority: .utility) {
            try? await store.append(newEvents)
        }
    }

    func record(_ event: ActivityEvent) {
        record([event])
    }

    /// Re-reads the log (the CLI may have added runs) and merges anything
    /// recorded in memory that is not on disk yet.
    func reload() async {
        let onDisk = (try? await storage.activity.events(since: nil)) ?? []
        let known = Set(onDisk.map(\.id))
        events = (onDisk + events.filter { !known.contains($0.id) }).sorted { $0.date < $1.date }
        recompute()
    }

    func clearHistory() async {
        try? await storage.activity.removeAll()
        events = []
        recompute()
    }

    private func recompute() {
        stats = ActivityStats(events: events, now: .now)
        recent = Array(events.suffix(recentLimit).reversed())
    }
}
