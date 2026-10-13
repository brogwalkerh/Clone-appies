import Foundation
import CleanerCore

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

    /// A fresh `ScanContext` reflecting the current settings and power state.
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

/// Minimal battery check for `ScanContext.isOnBattery`.
enum PowerState {
    static var isOnBattery: Bool {
        // ProcessInfo.isLowPowerModeEnabled is the only Foundation-level signal;
        // IOKit's power-source API lives in UIKitBridge once that package exists.
        // TODO(UIKitBridge): replace with IOPSCopyPowerSourcesInfo-based check.
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }
}
