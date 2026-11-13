import Foundation
import Testing
import CleanerCore
import CleanerCoreTesting
@testable import CleanupModule

@Suite("BrokenDownloadsScanner")
struct BrokenDownloadsScannerTests {
    let scanner = BrokenDownloadsScanner()

    var fs: MockFileSystem {
        [
            "/Users/test/Downloads/Big.pkg.download": .package(modified: daysAgo(20)),
            "/Users/test/Downloads/Big.pkg.download/Big.pkg": .file(size: 35_000),
            "/Users/test/Downloads/Big.pkg.download/Info.plist": .file(size: 200),
            "/Users/test/Downloads/movie.mp4.crdownload": .file(size: 1_000, modified: daysAgo(2)),
            "/Users/test/Downloads/iso.part": .file(size: 50, modified: daysAgo(1)),
            "/Users/test/Downloads/doc.partial": .file(size: 60, modified: daysAgo(300)),
            // Live or possibly-live downloads: must never be offered.
            "/Users/test/Downloads/live.mkv.crdownload": .file(size: 9_000, modified: daysAgo(0.01)),
            "/Users/test/Downloads/almost.part": .file(size: 9_000, modified: daysAgo(0.99)),
            "/Users/test/Downloads/undated.part": .file(size: 9_000),
            "/Users/test/Downloads/Live.dmg.download": .package(modified: daysAgo(3)),
            "/Users/test/Downloads/Live.dmg.download/Live.dmg": .file(size: 5_000, modified: daysAgo(0.001)),
            "/Users/test/Downloads/Live.dmg.download/Info.plist": .file(size: 200, modified: daysAgo(3)),
            "/Users/test/Downloads/Old-App.dmg": .file(size: 90_000, modified: daysAgo(95)),
            "/Users/test/Downloads/node.pkg": .file(size: 45_000, modified: daysAgo(30)),
            "/Users/test/Downloads/Fresh.dmg": .file(size: 70_000, modified: daysAgo(29)),
            "/Users/test/Downloads/photos.zip": .file(size: 60_000, modified: daysAgo(150)),
            "/Users/test/Downloads/undated.zip": .file(size: 10),
            "/Users/test/Downloads/Screenshot.png": .file(size: 2_000, modified: daysAgo(400)),
            "/Users/test/Downloads/invoice.pdf": .file(size: 150, modified: daysAgo(560)),
        ]
    }

    @Test func partialDownloadsAreSafe() async throws {
        let findings = try await collect(scanner, context(fs))
        let partial = findings.filter { $0.category.id == "cleanup.brokenDownloads" }
        #expect(partial.paths == [
            "/Users/test/Downloads/Big.pkg.download",
            "/Users/test/Downloads/movie.mp4.crdownload",
            "/Users/test/Downloads/iso.part",
            "/Users/test/Downloads/doc.partial",
        ])
        #expect(partial.allSatisfy { $0.risk == .safe && $0.scannerID == "cleanup.brokenDownloads" })
        let bundle = try #require(partial.named("Big.pkg.download"))
        #expect(bundle.isDirectory)
        #expect(bundle.sizeBytes == 35_200)
        #expect(bundle.modifiedAt == daysAgo(20))
        #expect(bundle.detail?.isEmpty == false)
    }

    @Test func oldInstallersUseInjectedNow() async throws {
        let findings = try await collect(scanner, context(fs))
        let old = findings.filter { $0.category.id == "cleanup.oldInstallers" }
        #expect(old.paths == [
            "/Users/test/Downloads/Old-App.dmg",
            "/Users/test/Downloads/node.pkg",
        ])
        // Review-only: never pre-selected.
        #expect(old.allSatisfy { $0.risk == .risky && !$0.isDirectory })
        // The date is the modification time, not a download time.
        #expect(old.named("Old-App.dmg")?.detail == "Modified 95 days ago")
        #expect(old.named("node.pkg")?.detail == "Modified 30 days ago")
        // Archives are not installers.
        #expect(findings.named("photos.zip") == nil)
        #expect(old.named("Old-App.dmg")?.sizeBytes == 90_000)
        #expect(findings.named("Fresh.dmg") == nil)
        #expect(findings.named("undated.zip") == nil)
        #expect(findings.named("Screenshot.png") == nil)
        #expect(findings.named("invoice.pdf") == nil)
    }

    @Test func movingNowForwardAgesInstallers() async throws {
        let later = context(fs, now: testNow.addingTimeInterval(2 * 86_400))
        let findings = try await collect(scanner, later)
        #expect(findings.named("Fresh.dmg")?.category.id == "cleanup.oldInstallers")
        #expect(findings.named("Fresh.dmg")?.detail == "Modified 31 days ago")
    }

    @Test func liveDownloadsAreNotOffered() async throws {
        let findings = try await collect(scanner, context(fs))
        #expect(findings.named("live.mkv.crdownload") == nil)
        #expect(findings.named("almost.part") == nil)
        #expect(findings.named("undated.part") == nil)
        // The bundle is 3 days old but a file inside it was just written.
        #expect(findings.named("Live.dmg.download") == nil)
    }

    @Test func partialDownloadsAgeIntoFindingsAfter24Hours() async throws {
        let later = context(fs, now: testNow.addingTimeInterval(86_400))
        let findings = try await collect(scanner, later)
        #expect(findings.named("live.mkv.crdownload")?.category.id == "cleanup.brokenDownloads")
        #expect(findings.named("almost.part") != nil)
        #expect(findings.named("Live.dmg.download") != nil)
        #expect(findings.named("undated.part") == nil)
    }

    @Test func missingDownloadsYieldsNothing() async throws {
        let fs: MockFileSystem = ["/Users/test/Desktop/a": .file(size: 1)]
        let findings = try await collect(scanner, context(fs))
        #expect(findings.isEmpty)
    }

    @Test func ignoreListIsRespected() async throws {
        let ignore = IgnoreList(paths: [URL(fileURLWithPath: "/Users/test/Downloads/Old-App.dmg")],
                                globs: ["*.crdownload"])
        let findings = try await collect(scanner, context(fs, ignore: ignore))
        #expect(findings.named("Old-App.dmg") == nil)
        #expect(findings.named("movie.mp4.crdownload") == nil)
        #expect(findings.named("node.pkg") != nil)
    }
}
