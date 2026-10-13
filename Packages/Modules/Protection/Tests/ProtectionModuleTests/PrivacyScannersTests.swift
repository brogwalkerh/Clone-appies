import Foundation
import Testing
import CleanerCore
import CleanerCoreTesting
@testable import ProtectionModule

@Suite("Privacy scanners")
struct PrivacyScannersTests {
    let home = "/Users/test"

    @Test func listMatchesContract() {
        let scanners = PrivacyScanners.all()
        let ids = scanners.map { type(of: $0).id }
        #expect(ids == [
            "privacy.safariHistory", "privacy.safariCookies", "privacy.chromiumHistory", "privacy.chromiumCookies",
            "privacy.chromiumCache", "privacy.firefoxHistory", "privacy.firefoxCookies", "privacy.firefoxCache",
            "privacy.recentItems", "privacy.quickLookCache", "privacy.wifiNetworks", "privacy.chatCaches",
        ])
        #expect(scanners.allSatisfy { $0.module == .protection && !$0.displayName.isEmpty })
    }

    @Test func nothingIsReportedOnAnEmptyHome() async throws {
        for scanner in PrivacyScanners.all() {
            let findings = try await collect(scanner, context(MockFileSystem([:])))
            #expect(findings.isEmpty, Comment(rawValue: type(of: scanner).id))
        }
    }

    @Test func safari() async throws {
        let fs: MockFileSystem = [
            "\(home)/Library/Safari/History.db": .file(size: 100),
            "\(home)/Library/Safari/History.db-wal": .file(size: 10),
            "\(home)/Library/Safari/Downloads.plist": .file(size: 5),
            "\(home)/Library/Safari/Bookmarks.plist": .file(size: 5),
            "\(home)/Library/Cookies/Cookies.binarycookies": .file(size: 7),
            "\(home)/Library/Safari/LocalStorage/a.localstorage": .file(size: 9),
        ]
        let history = try await collect(SafariHistoryScanner(), context(fs))
        #expect(history.names == ["History.db", "History.db-wal", "Downloads.plist"])
        #expect(history.allSatisfy { $0.category.id == "privacy.safariHistory" && $0.risk == .caution && $0.category.module == .protection })
        let cookies = try await collect(SafariCookiesScanner(), context(fs))
        #expect(cookies.names == ["Cookies.binarycookies", "LocalStorage"])
        #expect(cookies.first { $0.path.lastPathComponent == "LocalStorage" }?.sizeBytes == 9)
        #expect(cookies.allSatisfy { $0.category.id == "privacy.safariCookies" })
    }

    @Test func chromiumFamilyIncludingArc() async throws {
        let support = "\(home)/Library/Application Support"
        let fs: MockFileSystem = [
            "\(support)/Google/Chrome/Default/History": .file(size: 1),
            "\(support)/Google/Chrome/Default/Cookies": .file(size: 1),
            "\(support)/Google/Chrome/Default/Login Data": .file(size: 1),
            "\(support)/Google/Chrome/Default/Cache/x": .file(size: 1),
            "\(support)/Google/Chrome/Profile 2/Top Sites": .file(size: 1),
            "\(support)/Google/Chrome/Other/History": .file(size: 1),
            "\(support)/Arc/User Data/Default/History": .file(size: 1),
            "\(support)/Arc/User Data/Default/Network/Cookies": .file(size: 1),
            "\(support)/BraveSoftware/Brave-Browser/Profile 1/Visited Links": .file(size: 1),
            "\(support)/Microsoft Edge/Default/History": .file(size: 1),
            "\(support)/Vivaldi/Default/Cookies": .file(size: 1),
            "\(home)/Library/Caches/Google/Chrome/Default/Cache/y": .file(size: 1),
            "\(home)/Library/Caches/company.thebrowser.Browser/z": .file(size: 1),
        ]
        let history = try await collect(ChromiumHistoryScanner(), context(fs))
        #expect(history.paths == [
            "\(support)/Google/Chrome/Default/History",
            "\(support)/Google/Chrome/Profile 2/Top Sites",
            "\(support)/Arc/User Data/Default/History",
            "\(support)/BraveSoftware/Brave-Browser/Profile 1/Visited Links",
            "\(support)/Microsoft Edge/Default/History",
        ])
        #expect(history.first { $0.path.path.contains("Arc") }?.detail == "Arc Default browsing history")
        let cookies = try await collect(ChromiumCookiesScanner(), context(fs))
        #expect(cookies.paths == [
            "\(support)/Google/Chrome/Default/Cookies",
            "\(support)/Arc/User Data/Default/Network/Cookies",
            "\(support)/Vivaldi/Default/Cookies",
        ])
        let cache = try await collect(ChromiumCacheScanner(), context(fs))
        #expect(cache.paths == [
            "\(home)/Library/Caches/Google/Chrome",
            "\(home)/Library/Caches/company.thebrowser.Browser",
            "\(support)/Google/Chrome/Default/Cache",
        ])
        #expect(cache.allSatisfy { $0.isDirectory })
        for findings in [history, cookies, cache] {
            #expect(!findings.names.contains("Login Data"))
        }
    }

    @Test func firefox() async throws {
        let profiles = "\(home)/Library/Application Support/Firefox/Profiles"
        let fs: MockFileSystem = [
            "\(profiles)/abc.default-release/places.sqlite": .file(size: 1),
            "\(profiles)/abc.default-release/cookies.sqlite": .file(size: 1),
            "\(profiles)/abc.default-release/key4.db": .file(size: 1),
            "\(profiles)/abc.default-release/logins.json": .file(size: 1),
            "\(profiles)/abc.default-release/cache2/entries/x": .file(size: 1),
            "\(profiles)/xyz.dev/places.sqlite": .file(size: 1),
            "\(profiles)/profiles.ini": .file(size: 1),
            "\(home)/Library/Caches/Firefox/Profiles/abc.default-release/cache2/entries/y": .file(size: 3),
        ]
        let history = try await collect(FirefoxHistoryScanner(), context(fs))
        #expect(history.paths == ["\(profiles)/abc.default-release/places.sqlite", "\(profiles)/xyz.dev/places.sqlite"])
        #expect(history.allSatisfy { $0.risk == .risky && $0.detail == "Removes bookmarks too" && $0.category.id == "privacy.firefoxHistory" })
        let cookies = try await collect(FirefoxCookiesScanner(), context(fs))
        #expect(cookies.paths == ["\(profiles)/abc.default-release/cookies.sqlite"])
        #expect(cookies.allSatisfy { $0.risk == .caution })
        let cache = try await collect(FirefoxCacheScanner(), context(fs))
        #expect(cache.paths == ["\(profiles)/abc.default-release/cache2", "\(home)/Library/Caches/Firefox/Profiles/abc.default-release/cache2"])
    }

    @Test func systemAndChat() async throws {
        let fs: MockFileSystem = [
            "\(home)/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.RecentApplications.sfl3": .file(size: 1),
            "\(home)/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments/com.apple.textedit.sfl3": .file(size: 1),
            "\(home)/Library/Application Support/com.apple.sharedfilelist/readme.txt": .file(size: 1),
            "\(home)/Library/Caches/com.apple.QuickLook.thumbnailcache/index.sqlite": .file(size: 50),
            "/Library/Preferences/com.apple.wifi.known-networks.plist": .file(size: 20),
            "\(home)/Library/Application Support/Slack/Cache/a": .file(size: 1),
            "\(home)/Library/Application Support/discord/Code Cache/b": .file(size: 1),
            "\(home)/Library/Containers/desktop.WhatsApp/Data/Library/Caches/c": .file(size: 1),
        ]
        let recent = try await collect(RecentItemsScanner(), context(fs))
        #expect(recent.names == ["com.apple.LSSharedFileList.RecentApplications.sfl3", "com.apple.textedit.sfl3"])
        let quickLook = try await collect(QuickLookCacheScanner(), context(fs))
        #expect(quickLook.names == ["com.apple.QuickLook.thumbnailcache"])
        #expect(quickLook.first?.sizeBytes == 50)
        let wifi = try await collect(WiFiNetworksScanner(), context(fs))
        #expect(wifi.names == ["com.apple.wifi.known-networks.plist"])
        #expect(wifi.first?.risk == .risky)
        #expect(wifi.first?.detail?.contains("requiresHelper") == true)
        let chat = try await collect(ChatCachesScanner(), context(fs))
        #expect(chat.names == ["Cache", "Code Cache", "Caches"])
        #expect(Set(chat.compactMap(\.detail)) == ["Slack cache", "Discord cache", "WhatsApp cache"])
    }

    @Test func credentialStoresAreNeverReported() async throws {
        var tree: [String: MockFileSystem.Node] = [:]
        for directory in ["\(home)/Library/Application Support/Google/Chrome/Default",
                          "\(home)/Library/Application Support/Firefox/Profiles/p.default",
                          "\(home)/Library/Safari", "\(home)/Library/Keychains"] {
            for name in PrivacyScanners.neverReported {
                tree["\(directory)/\(name)"] = .file(size: 1)
            }
        }
        let fs = MockFileSystem(tree)
        for scanner in PrivacyScanners.all() {
            let findings = try await collect(scanner, context(fs))
            #expect(findings.isEmpty, Comment(rawValue: "\(type(of: scanner).id) reported \(findings.names)"))
        }
    }

    @Test func honoursIgnoreList() async throws {
        let fs: MockFileSystem = ["\(home)/Library/Safari/History.db": .file(size: 1)]
        let ignored = IgnoreList(paths: [URL(fileURLWithPath: "\(home)/Library/Safari")])
        #expect(try await collect(SafariHistoryScanner(), context(fs, ignore: ignored)).isEmpty)
    }
}
