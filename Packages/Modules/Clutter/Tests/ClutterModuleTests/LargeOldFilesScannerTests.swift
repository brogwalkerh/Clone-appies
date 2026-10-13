import Foundation
import Testing
import CleanerCore
import CleanerCoreTesting
@testable import ClutterModule

@Suite("LargeOldFilesScanner")
struct LargeOldFilesScannerTests {
    let scanner = LargeOldFilesScanner(minSizeBytes: 1_000_000, minAge: 180 * 86_400)

    var fs: MockFileSystem {
        [
            "/Users/test/Documents/big-fresh.mov": .file(size: 5_500_000, modified: daysAgo(1)),
            "/Users/test/Documents/big-old.iso": .file(size: 1_000_000, modified: daysAgo(400)),
            "/Users/test/Documents/small-old.txt": .file(size: 10, modified: daysAgo(180)),
            "/Users/test/Documents/small-fresh.txt": .file(size: 10, modified: daysAgo(179)),
            "/Users/test/Documents/undated.txt": .file(size: 10),
            "/Users/test/Documents/Nested/Deeper/ancient.doc": .file(size: 999_999, modified: daysAgo(1_000)),
            "/Users/test/Pictures/Photos.photoslibrary": .package(modified: daysAgo(900)),
            "/Users/test/Pictures/Photos.photoslibrary/orig.jpg": .file(size: 9_000_000, modified: daysAgo(900)),
            "/Users/test/Desktop/link": .symlink(to: "/Users/test/Documents/big-old.iso"),
            "/Users/test/Library/Caches/huge.bin": .file(size: 9_000_000, modified: daysAgo(900)),
            "/Users/test/Downloads/.hidden-old": .file(size: 1, modified: daysAgo(365)),
        ]
    }

    @Test func largeAndOldAreSplitByCategory() async throws {
        let findings = try await collect(scanner, context(fs))
        let large = findings.filter { $0.category.id == "clutter.largeFiles" }
        let old = findings.filter { $0.category.id == "clutter.oldFiles" }
        #expect(large.paths == [
            "/Users/test/Documents/big-fresh.mov",
            "/Users/test/Documents/big-old.iso",
        ])
        #expect(old.paths == [
            "/Users/test/Documents/small-old.txt",
            "/Users/test/Documents/Nested/Deeper/ancient.doc",
            "/Users/test/Downloads/.hidden-old",
        ])
        #expect(findings.allSatisfy { $0.risk == .caution && $0.scannerID == "clutter.largeOld" && !$0.isDirectory })
        #expect(findings.allSatisfy { $0.category.module == .clutter })
    }

    @Test func bothMatchingGoesToLargeOnly() async throws {
        let findings = try await collect(scanner, context(fs))
        let both = findings.filter { $0.path.lastPathComponent == "big-old.iso" }
        #expect(both.count == 1)
        #expect(both.first?.category.id == "clutter.largeFiles")
        #expect(both.first?.detail == "Large file, 1 MB")
        #expect(both.first?.sizeBytes == 1_000_000)
        #expect(both.first?.modifiedAt == daysAgo(400))
    }

    @Test func detailsAreHumanReadable() async throws {
        let findings = try await collect(scanner, context(fs))
        #expect(findings.named("big-fresh.mov")?.detail == "Large file, 5 MB")
        #expect(findings.named("small-old.txt")?.detail == "Not opened in 6 months")
        #expect(findings.named("ancient.doc")?.detail == "Not opened in 33 months")
    }

    @Test func thresholdsAreInclusiveAndUseInjectedNow() async throws {
        #expect(try await collect(scanner, context(fs)).named("small-fresh.txt") == nil)
        let later = context(fs, now: testNow.addingTimeInterval(86_400))
        let findings = try await collect(scanner, later)
        #expect(findings.named("small-fresh.txt")?.category.id == "clutter.oldFiles")
        #expect(findings.named("undated.txt") == nil)
    }

    @Test func packagesSymlinksAndNonRootsAreSkipped() async throws {
        let findings = try await collect(scanner, context(fs))
        #expect(findings.named("orig.jpg") == nil)
        #expect(findings.named("Photos.photoslibrary") == nil)
        #expect(findings.named("link") == nil)
        #expect(findings.named("huge.bin") == nil)
    }

    @Test func customRootsAndNestedRootsAreDeduplicated() async throws {
        let custom = LargeOldFilesScanner(minSizeBytes: 1_000_000, minAge: 180 * 86_400,
                                          roots: ["Library/Caches", "Documents/Nested", "Documents", "Missing"])
        let findings = try await collect(custom, context(fs))
        #expect(findings.named("huge.bin")?.category.id == "clutter.largeFiles")
        #expect(findings.filter { $0.path.lastPathComponent == "ancient.doc" }.count == 1)
    }

    @Test func ignoreListAndProtectedPathsAreRespected() async throws {
        let ignore = IgnoreList(paths: [URL(fileURLWithPath: "/Users/test/Documents/Nested")], globs: ["*.mov"])
        let protected = ProtectedPaths(prefixes: [URL(fileURLWithPath: "/Users/test/Downloads")])
        let findings = try await collect(scanner, context(fs, ignore: ignore, protected: protected))
        #expect(findings.paths == [
            "/Users/test/Documents/big-old.iso",
            "/Users/test/Documents/small-old.txt",
        ])
    }

    @Test func defaultsMatchContract() {
        let scanner = LargeOldFilesScanner()
        #expect(scanner.minSizeBytes == 100_000_000)
        #expect(scanner.minAge == 180 * 86_400)
        #expect(scanner.roots == ["Documents", "Desktop", "Downloads", "Movies", "Music", "Pictures"])
        #expect(LargeOldFilesScanner.id == "clutter.largeOld")
        #expect(scanner.module == .clutter)
    }
}
