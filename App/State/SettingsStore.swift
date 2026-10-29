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
        /// Protection (PLAN.md §3.3, ADR 0006): signature feed and quarantine policy.
        /// The Protection Monitor toggle lives in the shared suite (`MenuAgentSettings.Key.monitorEnabled`).
        static let signatureFeedURL = "protection.signatureFeedURL"
        static let autoUpdateSignatures = "protection.autoUpdateSignatures"
        static let quarantineRetentionDays = "protection.quarantineRetentionDays"
        /// Smart Care (M5): when the last full scan finished, for the Assistant and the hero.
        static let lastSmartCareScan = "smartCare.lastScan"
        /// When malware signatures last updated successfully, for the Assistant.
        static let signaturesUpdatedAt = "protection.signaturesUpdatedAt"
    }

    // MARK: Smart Care

    static func lastSmartCareScan() -> Date? {
        defaults.object(forKey: Key.lastSmartCareScan) as? Date
    }

    static func setLastSmartCareScan(_ date: Date) {
        defaults.set(date, forKey: Key.lastSmartCareScan)
    }

    static func signaturesUpdatedAt() -> Date? {
        defaults.object(forKey: Key.signaturesUpdatedAt) as? Date
    }

    // MARK: Protection

    /// Release channel that hosts `manifest.json` plus the ClamAV text files (ADR 0006).
    static let defaultSignatureFeedURL = "https://github.com/brogwalkerh/Clone-appies/releases/latest/download/"
    static let defaultQuarantineRetentionDays = 30

    /// The feed base URL from Settings › Protection, falling back to the project release channel
    /// when the stored string is empty or not a URL.
    static var signatureFeedURL: URL {
        let stored = defaults.string(forKey: Key.signatureFeedURL)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !stored.isEmpty, let url = URL(string: stored), url.scheme != nil {
            return url
        }
        // The default literal is a well-formed URL; `URL(string:)` only fails on malformed input.
        return URL(string: defaultSignatureFeedURL) ?? URL(fileURLWithPath: "/")
    }

    static func autoUpdateSignatures() -> Bool {
        guard defaults.object(forKey: Key.autoUpdateSignatures) != nil else { return true }
        return defaults.bool(forKey: Key.autoUpdateSignatures)
    }

    static func quarantineRetentionDays() -> Int {
        let stored = defaults.integer(forKey: Key.quarantineRetentionDays)
        return stored > 0 ? stored : defaultQuarantineRetentionDays
    }

    /// `~/Library/Application Support/com.example.maccleaner`, created on demand.
    static func applicationSupportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let directory = base.appendingPathComponent("com.example.maccleaner", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Where `ThreatQuarantine` stores quarantined items (`<uuid>/` folders plus manifests).
    static func quarantineDirectory() -> URL {
        applicationSupportDirectory().appendingPathComponent("Quarantine", isDirectory: true)
    }

    /// Where `SignatureUpdater` writes downloaded `.hdb` / `.ndb` / `.ign2` files and the version marker.
    static func signaturesDirectory() -> URL {
        applicationSupportDirectory().appendingPathComponent("signatures", isDirectory: true)
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
