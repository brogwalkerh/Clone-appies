import Foundation
import CleanerCore
import UIKitBridge

/// Keys and typed accessors for `UserDefaults`-backed settings. `SettingsView`
/// binds to the same keys via `@AppStorage`; view models read them here so a
/// scan always picks up the current ignore list and removal mode.
enum SettingsStore {
    enum Key {
        static let removalMode = "settings.removalMode"
        static let showMenuBarAgent = "settings.showMenuBarAgent"
        static let ignoreListPaths = "settings.ignoreList.paths"
        static let hasCompletedOnboarding = "onboarding.completed"
        static let pinnedTools = "sidebar.pinnedTools"
        /// My Clutter › Large & Old thresholds (PLAN.md §3.6), bound to sliders.
        static let largeOldMinSizeMB = "clutter.largeOld.minSizeMB"
        static let largeOldMinAgeDays = "clutter.largeOld.minAgeDays"
    }

    /// Defaults mirror `LargeOldFilesScanner.init` (100 MB, 180 days).
    static let defaultLargeOldMinSizeMB: Double = 100
    static let defaultLargeOldMinAgeDays: Double = 180

    static func largeOldMinSizeMB() -> Double {
        let stored = defaults.double(forKey: Key.largeOldMinSizeMB)
        return stored > 0 ? stored : defaultLargeOldMinSizeMB
    }

    static func largeOldMinAgeDays() -> Double {
        guard defaults.object(forKey: Key.largeOldMinAgeDays) != nil else {
            return defaultLargeOldMinAgeDays
        }
        return max(defaults.double(forKey: Key.largeOldMinAgeDays), 0)
    }

    static var defaults: UserDefaults { .standard }

    static func removalMode() -> RemovalMode {
        RemovalMode(rawValue: defaults.string(forKey: Key.removalMode) ?? "") ?? .trash
    }

    static func ignoredPaths() -> [String] {
        defaults.stringArray(forKey: Key.ignoreListPaths) ?? []
    }

    static func setIgnoredPaths(_ paths: [String]) {
        defaults.set(paths, forKey: Key.ignoreListPaths)
    }

    static func ignoreList() -> IgnoreList {
        let urls = ignoredPaths().map { URL(fileURLWithPath: $0).standardizedFileURL }
        return IgnoreList(paths: Set(urls), globs: [])
    }

    /// A fresh `ScanContext` reflecting the current settings and power state
    /// (`PowerState` is UIKitBridge's IOKit-backed check).
    static func scanContext() -> ScanContext {
        ScanContext(
            fileSystem: LocalFileSystem(),
            home: nil,
            ignoreList: ignoreList(),
            protectedPaths: .default,
            isOnBattery: PowerState.isOnBattery,
            now: .now
        )
    }

    /// Clears every key this app owns. Used by Settings › Advanced › Reset.
    static func resetAll() {
        if let bundleID = Bundle.main.bundleIdentifier {
            defaults.removePersistentDomain(forName: bundleID)
        }
    }
}
