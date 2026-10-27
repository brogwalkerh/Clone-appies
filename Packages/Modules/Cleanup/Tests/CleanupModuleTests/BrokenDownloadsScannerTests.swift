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
            "/Users/test/Downloads/iso.part": .file(size: 50),
            "/Users/test/Downloads/doc.partial": .file(size: 60),
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
            "/Users/test/Downloads/photos.zip",
        ])
        #expect(old.allSatisfy { $0.risk == .caution && !$0.isDirectory })
        #expect(old.named("Old-App.dmg")?.detail == "Downloaded 95 days ago")
        #expect(old.named("node.pkg")?.detail == "Downloaded 30 days ago")
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
        #expect(findings.named("Fresh.dmg")?.detail == "Downloaded 31 days ago")
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
