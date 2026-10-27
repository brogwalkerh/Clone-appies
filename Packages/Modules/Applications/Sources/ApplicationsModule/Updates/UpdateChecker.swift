import Foundation
import CleanerCore

/// Fans an update check out to every source and merges the answers by app,
/// keeping the highest version reported for each.
public actor UpdateChecker {
    private let sources: [any UpdateSource]
    private let maxConcurrency: Int

    public init(sources: [any UpdateSource]) {
        self.init(sources: sources, maxConcurrency: 3)
    }

    /// Additional initializer bounding how many sources run at once.
    public init(sources: [any UpdateSource], maxConcurrency: Int) {
        self.sources = sources
        self.maxConcurrency = max(1, maxConcurrency)
    }

    public func check(_ apps: [InstalledApp]) async -> [AvailableUpdate] {
        guard !sources.isEmpty, !apps.isEmpty else { return [] }
        let sources = self.sources
        let limit = maxConcurrency

        var bySource: [(index: Int, updates: [AvailableUpdate])] = []
        await withTaskGroup(of: (Int, [AvailableUpdate]).self) { group in
            var next = 0
            func enqueue() {
                let index = next
                let source = sources[index]
                next += 1
                group.addTask { (index, await source.check(apps)) }
            }
            while next < sources.count && next < limit { enqueue() }
            for await (index, updates) in group {
                bySource.append((index, updates))
                if next < sources.count && !Task.isCancelled { enqueue() }
            }
        }
        // Source order, not arrival order, decides ties.
        return Self.merge(bySource.sorted { $0.index < $1.index }.flatMap(\.updates))
    }

    /// One update per app: the highest `latestVersion`, ties broken in favour
    /// of the earliest source. Sorted by app name.
    static func merge(_ updates: [AvailableUpdate]) -> [AvailableUpdate] {
        var best: [URL: AvailableUpdate] = [:]
        var order: [URL] = []
        for update in updates {
            let key = update.app.bundleURL.standardizedFileURL
            if let existing = best[key] {
                if VersionComparator.isNewer(update.latestVersion, than: existing.latestVersion) {
                    best[key] = update
                }
            } else {
                best[key] = update
                order.append(key)
            }
        }
        return order.compactMap { best[$0] }.sorted {
            let byName = $0.app.name.localizedCaseInsensitiveCompare($1.app.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return $0.app.bundleURL.path < $1.app.bundleURL.path
        }
    }
}
