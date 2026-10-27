import Foundation
import CleanerCore

/// Path-based privacy scanners, one per data kind. Each reports only paths
/// that exist, with category "privacy.<kind>" and risk `.caution` unless noted.
/// Credential stores (browser "Login Data", Firefox key4.db / logins.json,
/// keychains) are never reported.
public enum PrivacyScanners {
    public static func all() -> [any CleanerScanner] {
        [
            SafariHistoryScanner(),
            SafariCookiesScanner(),
            ChromiumHistoryScanner(),
            ChromiumCookiesScanner(),
            ChromiumCacheScanner(),
            FirefoxHistoryScanner(),
            FirefoxCookiesScanner(),
            FirefoxCacheScanner(),
            RecentItemsScanner(),
            QuickLookCacheScanner(),
            WiFiNetworksScanner(),
            ChatCachesScanner(),
        ]
    }

    /// File names that are credential stores and must never be emitted.
    public static let neverReported: Set<String> = [
        "Login Data", "Login Data-journal", "Login Data For Account", "Login Data For Account-journal",
        "key4.db", "key3.db", "logins.json", "logins-backup.json", "signons.sqlite",
        "login.keychain", "login.keychain-db", "Keychain", "Keychains",
    ]

    /// Chromium-family browsers: display name, profile root under
    /// ~/Library/Application Support, cache folder under ~/Library/Caches.
    public struct ChromiumBrowser: Sendable, Hashable {
        public let name: String
        public let supportPath: String
        public let cachePath: String?
    }

    public static let chromiumBrowsers: [ChromiumBrowser] = [
        ChromiumBrowser(name: "Chrome", supportPath: "Google/Chrome", cachePath: "Google/Chrome"),
        ChromiumBrowser(name: "Chrome Beta", supportPath: "Google/Chrome Beta", cachePath: "Google/Chrome Beta"),
        ChromiumBrowser(name: "Chrome Canary", supportPath: "Google/Chrome Canary", cachePath: "Google/Chrome Canary"),
        ChromiumBrowser(name: "Chromium", supportPath: "Chromium", cachePath: "Chromium"),
        ChromiumBrowser(name: "Brave", supportPath: "BraveSoftware/Brave-Browser", cachePath: "BraveSoftware/Brave-Browser"),
        ChromiumBrowser(name: "Edge", supportPath: "Microsoft Edge", cachePath: "Microsoft Edge"),
        ChromiumBrowser(name: "Arc", supportPath: "Arc/User Data", cachePath: "company.thebrowser.Browser"),
        ChromiumBrowser(name: "Vivaldi", supportPath: "Vivaldi", cachePath: "com.vivaldi.Vivaldi"),
    ]
}

// MARK: - Shared plumbing

extension ScanContext {
    /// Emits one finding per existing, non-credential path in `candidates`.
    func emitPrivacy(_ candidates: [(url: URL, detail: String)], category: FindingCategory,
                     scannerID: String, risk: RiskLevel, emitter: FindingEmitter) async throws {
        var seen = Set<String>()
        for candidate in candidates {
            try Task.checkCancellation()
            let url = candidate.url.standardizedFileURL
            if PrivacyScanners.neverReported.contains(url.lastPathComponent) { continue }
            guard seen.insert(url.path).inserted else { continue }
            if let finding = await finding(at: url, category: category, scannerID: scannerID,
                                           risk: risk, detail: candidate.detail) {
                emitter.emit(finding)
            }
        }
    }

    /// `(browser, profile directory)` for every Chromium-family profile present.
    func chromiumProfiles() -> [(browser: PrivacyScanners.ChromiumBrowser, profile: URL)] {
        var profiles: [(PrivacyScanners.ChromiumBrowser, URL)] = []
        for browser in PrivacyScanners.chromiumBrowsers {
            let root = homePath("Library/Application Support/\(browser.supportPath)")
            for child in childDirectories(of: root) {
                let name = child.lastPathComponent
                if name == "Default" || name.hasPrefix("Profile ") || name == "Guest Profile" {
                    profiles.append((browser, child))
                }
            }
        }
        return profiles
    }

    /// Firefox profile directories.
    func firefoxProfiles() -> [URL] {
        childDirectories(of: homePath("Library/Application Support/Firefox/Profiles"))
    }

    /// `name` and its SQLite side files (`-wal`, `-shm`, `-journal`) inside `directory`.
    func sqliteFamily(_ name: String, in directory: URL) -> [URL] {
        [name, name + "-wal", name + "-shm", name + "-journal"].map { directory.appendingPathComponent($0) }
    }
}

// MARK: - Safari

public struct SafariHistoryScanner: CleanerScanner {
    public static let id = "privacy.safariHistory"
    public let displayName = "Safari History"
    public let module = ModuleID.protection
    public init() {}

    public func scan(_ context: ScanContext) -> AsyncThrowingStream<Finding, any Error> {
        makeFindingStream { emitter in
            var candidates: [(URL, String)] = []
            for base in [context.homePath("Library/Safari"),
                         context.homePath("Library/Containers/com.apple.Safari/Data/Library/Safari")] {
                candidates += context.sqliteFamily("History.db", in: base).map { ($0, "Browsing history") }
                candidates.append((base.appendingPathComponent("Downloads.plist"), "Download history"))
                candidates.append((base.appendingPathComponent("LastSession.plist"), "Last session"))
                candidates.append((base.appendingPathComponent("RecentlyClosedTabs.plist"), "Recently closed tabs"))
            }
            try await context.emitPrivacy(candidates.map { (url: $0.0, detail: $0.1) },
                                          category: ProtectionCategory.privacy("safariHistory", "Safari History"),
                                          scannerID: Self.id, risk: .caution, emitter: emitter)
        }
    }
}

public struct SafariCookiesScanner: CleanerScanner {
    public static let id = "privacy.safariCookies"
    public let displayName = "Safari Cookies & Site Data"
    public let module = ModuleID.protection
    public init() {}

    public func scan(_ context: ScanContext) -> AsyncThrowingStream<Finding, any Error> {
        makeFindingStream { emitter in
            let candidates: [(url: URL, detail: String)] = [
                (context.homePath("Library/Cookies/Cookies.binarycookies"), "Cookies"),
                (context.homePath("Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"), "Cookies"),
                (context.homePath("Library/Safari/LocalStorage"), "Website local storage"),
                (context.homePath("Library/Safari/Databases"), "Website databases"),
                (context.homePath("Library/Containers/com.apple.Safari/Data/Library/Safari/LocalStorage"), "Website local storage"),
            ]
            try await context.emitPrivacy(candidates,
                                          category: ProtectionCategory.privacy("safariCookies", "Safari Cookies & Site Data"),
                                          scannerID: Self.id, risk: .caution, emitter: emitter)
        }
    }
}

// MARK: - Chromium family

public struct ChromiumHistoryScanner: CleanerScanner {
    public static let id = "privacy.chromiumHistory"
    public let displayName = "Browser History"
    public let module = ModuleID.protection
    public init() {}

    public func scan(_ context: ScanContext) -> AsyncThrowingStream<Finding, any Error> {
        makeFindingStream { emitter in
            var candidates: [(url: URL, detail: String)] = []
            for (browser, profile) in context.chromiumProfiles() {
                let label = "\(browser.name) \(profile.lastPathComponent)"
                candidates += context.sqliteFamily("History", in: profile).map { ($0, "\(label) browsing history") }
                candidates += context.sqliteFamily("Top Sites", in: profile).map { ($0, "\(label) top sites") }
                candidates += context.sqliteFamily("Shortcuts", in: profile).map { ($0, "\(label) omnibox shortcuts") }
                candidates.append((profile.appendingPathComponent("Visited Links"), "\(label) visited links"))
            }
            try await context.emitPrivacy(candidates,
                                          category: ProtectionCategory.privacy("chromiumHistory", "Browser History"),
                                          scannerID: Self.id, risk: .caution, emitter: emitter)
        }
    }
}

public struct ChromiumCookiesScanner: CleanerScanner {
    public static let id = "privacy.chromiumCookies"
    public let displayName = "Browser Cookies"
    public let module = ModuleID.protection
    public init() {}

    public func scan(_ context: ScanContext) -> AsyncThrowingStream<Finding, any Error> {
        makeFindingStream { emitter in
            var candidates: [(url: URL, detail: String)] = []
            for (browser, profile) in context.chromiumProfiles() {
                let label = "\(browser.name) \(profile.lastPathComponent)"
                candidates += context.sqliteFamily("Cookies", in: profile).map { ($0, "\(label) cookies") }
                candidates += context.sqliteFamily("Cookies", in: profile.appendingPathComponent("Network"))
                    .map { ($0, "\(label) cookies") }
            }
            try await context.emitPrivacy(candidates,
                                          category: ProtectionCategory.privacy("chromiumCookies", "Browser Cookies"),
                                          scannerID: Self.id, risk: .caution, emitter: emitter)
        }
    }
}

public struct ChromiumCacheScanner: CleanerScanner {
    public static let id = "privacy.chromiumCache"
    public let displayName = "Browser Cache"
    public let module = ModuleID.protection
    public init() {}

    public func scan(_ context: ScanContext) -> AsyncThrowingStream<Finding, any Error> {
        makeFindingStream { emitter in
            var candidates: [(url: URL, detail: String)] = []
            for browser in PrivacyScanners.chromiumBrowsers {
                if let cache = browser.cachePath {
                    candidates.append((context.homePath("Library/Caches/\(cache)"), "\(browser.name) cache"))
                }
            }
            for (browser, profile) in context.chromiumProfiles() {
                let label = "\(browser.name) \(profile.lastPathComponent)"
                for folder in ["Cache", "Code Cache", "GPUCache", "Service Worker/CacheStorage"] {
                    candidates.append((profile.appendingPathComponent(folder), "\(label) \(folder.lowercased())"))
                }
            }
            try await context.emitPrivacy(candidates,
                                          category: ProtectionCategory.privacy("chromiumCache", "Browser Cache"),
                                          scannerID: Self.id, risk: .caution, emitter: emitter)
        }
    }
}

// MARK: - Firefox

public struct FirefoxHistoryScanner: CleanerScanner {
    public static let id = "privacy.firefoxHistory"
    public let displayName = "Firefox History"
    public let module = ModuleID.protection
    public init() {}

    public func scan(_ context: ScanContext) -> AsyncThrowingStream<Finding, any Error> {
        makeFindingStream { emitter in
            var candidates: [(url: URL, detail: String)] = []
            for profile in context.firefoxProfiles() {
                candidates += context.sqliteFamily("places.sqlite", in: profile).map { ($0, "Removes bookmarks too") }
            }
            try await context.emitPrivacy(candidates,
                                          category: ProtectionCategory.privacy("firefoxHistory", "Firefox History"),
                                          scannerID: Self.id, risk: .risky, emitter: emitter)
        }
    }
}

public struct FirefoxCookiesScanner: CleanerScanner {
    public static let id = "privacy.firefoxCookies"
    public let displayName = "Firefox Cookies"
    public let module = ModuleID.protection
    public init() {}

    public func scan(_ context: ScanContext) -> AsyncThrowingStream<Finding, any Error> {
        makeFindingStream { emitter in
            var candidates: [(url: URL, detail: String)] = []
            for profile in context.firefoxProfiles() {
                let label = profile.lastPathComponent
                candidates += context.sqliteFamily("cookies.sqlite", in: profile).map { ($0, "\(label) cookies") }
                candidates.append((profile.appendingPathComponent("sessionstore-backups"), "\(label) session store"))
            }
            try await context.emitPrivacy(candidates,
                                          category: ProtectionCategory.privacy("firefoxCookies", "Firefox Cookies"),
                                          scannerID: Self.id, risk: .caution, emitter: emitter)
        }
    }
}

public struct FirefoxCacheScanner: CleanerScanner {
    public static let id = "privacy.firefoxCache"
    public let displayName = "Firefox Cache"
    public let module = ModuleID.protection
    public init() {}

    public func scan(_ context: ScanContext) -> AsyncThrowingStream<Finding, any Error> {
        makeFindingStream { emitter in
            var candidates: [(url: URL, detail: String)] = []
            for profile in context.firefoxProfiles() {
                candidates.append((profile.appendingPathComponent("cache2"), "\(profile.lastPathComponent) cache"))
            }
            for profile in context.childDirectories(of: context.homePath("Library/Caches/Firefox/Profiles")) {
                candidates.append((profile.appendingPathComponent("cache2"), "\(profile.lastPathComponent) cache"))
            }
            try await context.emitPrivacy(candidates,
                                          category: ProtectionCategory.privacy("firefoxCache", "Firefox Cache"),
                                          scannerID: Self.id, risk: .caution, emitter: emitter)
        }
    }
}

// MARK: - System

public struct RecentItemsScanner: CleanerScanner {
    public static let id = "privacy.recentItems"
    public let displayName = "Recent Items"
    public let module = ModuleID.protection
    public init() {}

    public func scan(_ context: ScanContext) -> AsyncThrowingStream<Finding, any Error> {
        makeFindingStream { emitter in
            let root = context.homePath("Library/Application Support/com.apple.sharedfilelist")
            var candidates: [(url: URL, detail: String)] = []
            for child in context.readableChildren(of: root) {
                if child.pathExtension.lowercased() == "sfl3" {
                    candidates.append((child, "Recent items list"))
                } else {
                    for nested in context.readableChildren(of: child) where nested.pathExtension.lowercased() == "sfl3" {
                        candidates.append((nested, "Recent documents (\(child.lastPathComponent))"))
                    }
                }
            }
            try await context.emitPrivacy(candidates,
                                          category: ProtectionCategory.privacy("recentItems", "Recent Items"),
                                          scannerID: Self.id, risk: .caution, emitter: emitter)
        }
    }
}

public struct QuickLookCacheScanner: CleanerScanner {
    public static let id = "privacy.quickLookCache"
    public let displayName = "QuickLook Thumbnail Cache"
    public let module = ModuleID.protection
    public init() {}

    public func scan(_ context: ScanContext) -> AsyncThrowingStream<Finding, any Error> {
        makeFindingStream { emitter in
            let candidates: [(url: URL, detail: String)] = [
                (context.homePath("Library/Caches/com.apple.QuickLook.thumbnailcache"), "Thumbnails of previewed files"),
            ]
            try await context.emitPrivacy(candidates,
                                          category: ProtectionCategory.privacy("quickLookCache", "QuickLook Thumbnail Cache"),
                                          scannerID: Self.id, risk: .caution, emitter: emitter)
        }
    }
}

/// Report-only: the known-networks list lives under /Library and removing it
/// needs the privileged helper, so it is `.risky` with a "requiresHelper" detail.
public struct WiFiNetworksScanner: CleanerScanner {
    public static let id = "privacy.wifiNetworks"
    public let displayName = "Wi-Fi Known Networks"
    public let module = ModuleID.protection
    public init() {}

    public func scan(_ context: ScanContext) -> AsyncThrowingStream<Finding, any Error> {
        makeFindingStream { emitter in
            let detail = "Forgets every saved Wi-Fi network (requiresHelper)"
            let candidates: [(url: URL, detail: String)] = [
                (URL(fileURLWithPath: "/Library/Preferences/com.apple.wifi.known-networks.plist"), detail),
                (URL(fileURLWithPath: "/Library/Preferences/SystemConfiguration/com.apple.airport.preferences.plist"), detail),
            ]
            try await context.emitPrivacy(candidates,
                                          category: ProtectionCategory.privacy("wifiNetworks", "Wi-Fi Known Networks"),
                                          scannerID: Self.id, risk: .risky, emitter: emitter)
        }
    }
}

public struct ChatCachesScanner: CleanerScanner {
    public static let id = "privacy.chatCaches"
    public let displayName = "Chat App Caches"
    public let module = ModuleID.protection
    public init() {}

    /// (app, home-relative cache path)
    public static let locations: [(app: String, path: String)] = [
        ("Slack", "Library/Application Support/Slack/Cache"),
        ("Slack", "Library/Application Support/Slack/Service Worker/CacheStorage"),
        ("Slack", "Library/Containers/com.tinyspeck.slackmacgap/Data/Library/Application Support/Slack/Cache"),
        ("Slack", "Library/Containers/com.tinyspeck.slackmacgap/Data/Library/Caches"),
        ("Discord", "Library/Application Support/discord/Cache"),
        ("Discord", "Library/Application Support/discord/Code Cache"),
        ("Teams", "Library/Application Support/Microsoft/Teams/Cache"),
        ("Teams", "Library/Containers/com.microsoft.teams2/Data/Library/Caches"),
        ("Telegram", "Library/Caches/ru.keepcoder.Telegram"),
        ("Telegram", "Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram/appstore/account-0/postbox/media"),
        ("WhatsApp", "Library/Application Support/WhatsApp/Cache"),
        ("WhatsApp", "Library/Containers/desktop.WhatsApp/Data/Library/Caches"),
    ]

    public func scan(_ context: ScanContext) -> AsyncThrowingStream<Finding, any Error> {
        makeFindingStream { emitter in
            let candidates = Self.locations.map { (url: context.homePath($0.path), detail: "\($0.app) cache") }
            try await context.emitPrivacy(candidates,
                                          category: ProtectionCategory.privacy("chatCaches", "Chat App Caches"),
                                          scannerID: Self.id, risk: .caution, emitter: emitter)
        }
    }
}
