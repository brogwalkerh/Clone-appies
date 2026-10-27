import Foundation
import Testing
import CleanerCore
import CleanerCoreTesting
@testable import CleanupModule

@Suite("UserCachesScanner")
struct UserCachesScannerTests {
    let scanner = UserCachesScanner()

    var fs: MockFileSystem {
        [
            "/Users/test/Library/Caches/com.example.app/Cache.db": .file(size: 1_000, modified: daysAgo(3)),
            "/Users/test/Library/Caches/com.example.app/fsCachedData/blob": .file(size: 2_000),
            "/Users/test/Library/Caches/com.example.empty": .directory(modified: daysAgo(1)),
            "/Users/test/Library/Caches/com.apple.Safari/WebKit/blob": .file(size: 500),
            "/Users/test/Library/Caches/com.spotify.client/Storage/x": .file(size: 700),
            "/Users/test/Library/Caches/com.apple.bird/sync.db": .file(size: 9_999),
            "/Users/test/Library/Caches/CloudKit/db": .file(size: 9_999),
            "/Users/test/Library/Caches/com.apple.nsurlsessiond/x": .file(size: 9_999),
            "/Users/test/Library/Caches/Homebrew/downloads/a.tar.gz": .file(size: 4_000),
            "/Users/test/Library/Caches/com.apple.dt.Xcode/Downloads/stub": .file(size: 4_000),
            "/Users/test/Library/Caches/stray.bin": .file(size: 10),
        ]
    }

    @Test func eachCacheDirectoryIsOneFinding() async throws {
        let findings = try await collect(scanner, context(fs))
        let app = try #require(findings.named("com.example.app"))
        #expect(app.category.id == "cleanup.userCaches")
        #expect(app.category.displayName == "User Cache Files")
        #expect(app.scannerID == "cleanup.userCaches")
        #expect(app.sizeBytes == 3_000)
        #expect(app.isDirectory)
        #expect(app.risk == .safe)
        #expect(app.modifiedAt == nil)   // implicit directory has no mtime
        #expect(app.detail?.isEmpty == false)

        let empty = try #require(findings.named("com.example.empty"))
        #expect(empty.sizeBytes == 0)
        #expect(empty.modifiedAt == daysAgo(1))

        let stray = try #require(findings.named("stray.bin"))
        #expect(!stray.isDirectory)
        #expect(stray.sizeBytes == 10)
    }

    @Test func reLoginCachesAreCaution() async throws {
        let findings = try await collect(scanner, context(fs))
        #expect(findings.named("com.apple.Safari")?.risk == .caution)
        #expect(findings.named("com.spotify.client")?.risk == .caution)
        #expect(findings.named("com.apple.Safari")?.detail?.contains("Safari") == true)
    }

    @Test func protectedSystemCachesAreSkipped() async throws {
        let findings = try await collect(scanner, context(fs))
        #expect(findings.named("com.apple.bird") == nil)
        #expect(findings.named("CloudKit") == nil)
        #expect(findings.named("com.apple.nsurlsessiond") == nil)
    }

    @Test func entriesOwnedByOtherScannersAreSkipped() async throws {
        let findings = try await collect(scanner, context(fs))
        #expect(findings.named("Homebrew") == nil)
        #expect(findings.named("com.apple.dt.Xcode") == nil)
    }

    @Test func missingParentYieldsNothing() async throws {
        let fs: MockFileSystem = ["/Users/test/Documents/a.txt": .file(size: 1)]
        let findings = try await collect(scanner, context(fs))
        #expect(findings.isEmpty)
    }

    @Test func ignoreListIsRespected() async throws {
        let ignore = IgnoreList(paths: [URL(fileURLWithPath: "/Users/test/Library/Caches/com.example.app")],
                                globs: ["com.spotify.*"])
        let findings = try await collect(scanner, context(fs, ignore: ignore))
        #expect(findings.named("com.example.app") == nil)
        #expect(findings.named("com.spotify.client") == nil)
        #expect(findings.named("com.apple.Safari") != nil)
    }

    @Test func protectedPathsAreRespected() async throws {
        let protected = ProtectedPaths(prefixes: [URL(fileURLWithPath: "/Users/test/Library/Caches/com.apple.Safari")])
        let findings = try await collect(scanner, context(fs, protected: protected))
        #expect(findings.named("com.apple.Safari") == nil)
        #expect(findings.named("com.example.app") != nil)
    }

    @Test func customHomeIsHonored() async throws {
        let fs: MockFileSystem = ["/Volumes/Other/Library/Caches/com.x.y/a": .file(size: 5)]
        let ctx = ScanContext(fileSystem: fs, home: URL(fileURLWithPath: "/Volumes/Other"),
                              protectedPaths: .none, now: testNow)
        let findings = try await collect(scanner, ctx)
        #expect(findings.paths == ["/Volumes/Other/Library/Caches/com.x.y"])
    }
}
