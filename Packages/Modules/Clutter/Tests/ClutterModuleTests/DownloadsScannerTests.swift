import Foundation
import Testing
import CleanerCore
import CleanerCoreTesting
@testable import ClutterModule

@Suite("DownloadsScanner")
struct DownloadsScannerTests {
    let scanner = DownloadsScanner()

    var fs: MockFileSystem {
        [
            "/Users/test/Downloads/Fresh.dmg": .file(size: 10_000, modified: daysAgo(1)),
            "/Users/test/Downloads/old.PKG": .file(size: 20_000, modified: daysAgo(200)),
            "/Users/test/Downloads/photos.zip": .file(size: 30_000),
            "/Users/test/Downloads/Installer.mpkg": .package(modified: daysAgo(5)),
            "/Users/test/Downloads/Installer.mpkg/Contents/payload": .file(size: 40_000),
            "/Users/test/Downloads/Screenshot 2026-10-01 at 10.00.00.png": .file(size: 500, modified: daysAgo(100)),
            "/Users/test/Downloads/Screen Recording 2026-10-02.mov": .file(size: 600, modified: daysAgo(1)),
            "/Users/test/Downloads/invoice.pdf": .file(size: 700, modified: daysAgo(90)),
            "/Users/test/Downloads/recent.pdf": .file(size: 800, modified: daysAgo(89)),
            "/Users/test/Downloads/undated.pdf": .file(size: 900),
            "/Users/test/Downloads/Old Folder": .directory(modified: daysAgo(400)),
            "/Users/test/Downloads/Old Folder/a.txt": .file(size: 1_000),
            "/Users/test/Downloads/Old Folder/Sub/b.txt": .file(size: 2_000),
            "/Users/test/Downloads/Old Folder/Sub/nested-old.dmg": .file(size: 3_000, modified: daysAgo(400)),
            "/Users/test/Downloads/New Folder": .directory(modified: daysAgo(1)),
            "/Users/test/Downloads/New Folder/c.txt": .file(size: 4_000, modified: daysAgo(400)),
            "/Users/test/Downloads/Big.pkg.download": .package(modified: daysAgo(100)),
            "/Users/test/Downloads/Big.pkg.download/Big.pkg": .file(size: 5_000),
            "/Users/test/Downloads/.localized": .file(size: 0, modified: daysAgo(1_000)),
            "/Users/test/Downloads/link.dmg": .symlink(to: "/Users/test/Downloads/Fresh.dmg"),
            "/Users/test/Desktop/Screenshot elsewhere.png": .file(size: 1, modified: daysAgo(500)),
        ]
    }

    @Test func rulesAndPrecedence() async throws {
        let findings = try await collect(scanner, context(fs))
        #expect(findings.paths == [
            "/Users/test/Downloads/Fresh.dmg",
            "/Users/test/Downloads/old.PKG",
            "/Users/test/Downloads/photos.zip",
            "/Users/test/Downloads/Installer.mpkg",
            "/Users/test/Downloads/Screenshot 2026-10-01 at 10.00.00.png",
            "/Users/test/Downloads/Screen Recording 2026-10-02.mov",
            "/Users/test/Downloads/invoice.pdf",
            "/Users/test/Downloads/Old Folder",
        ])
        #expect(findings.named("Fresh.dmg")?.detail == "Installer")
        #expect(findings.named("old.PKG")?.detail == "Installer", "installer rule wins over stale")
        #expect(findings.named("photos.zip")?.detail == "Installer")
        #expect(findings.named("Installer.mpkg")?.detail == "Installer")
        #expect(findings.named("Screenshot 2026-10-01 at 10.00.00.png")?.detail == "Screenshot", "screenshot rule wins over stale")
        #expect(findings.named("Screen Recording 2026-10-02.mov")?.detail == "Screenshot")
        #expect(findings.named("invoice.pdf")?.detail == "Downloaded 90 days ago")
        #expect(findings.named("Old Folder")?.detail == "Downloaded 400 days ago")
        #expect(findings.allSatisfy { $0.risk == .caution && $0.category.id == "clutter.downloads" })
        #expect(findings.allSatisfy { $0.scannerID == "clutter.downloads" })
    }

    @Test func foldersAreSizedRecursivelyAndNotEntered() async throws {
        let findings = try await collect(scanner, context(fs))
        let folder = try #require(findings.named("Old Folder"))
        #expect(folder.isDirectory)
        #expect(folder.sizeBytes == 6_000)
        #expect(folder.modifiedAt == daysAgo(400))
        let bundle = try #require(findings.named("Installer.mpkg"))
        #expect(bundle.isDirectory && bundle.sizeBytes == 40_000)
        #expect(findings.named("nested-old.dmg") == nil)
        #expect(findings.named("c.txt") == nil)
        #expect(findings.named("New Folder") == nil)
    }

    @Test func nonMatchingHiddenPartialAndSymlinkItemsAreSkipped() async throws {
        let findings = try await collect(scanner, context(fs))
        #expect(findings.named("recent.pdf") == nil)
        #expect(findings.named("undated.pdf") == nil)
        #expect(findings.named(".localized") == nil)
        #expect(findings.named("Big.pkg.download") == nil)
        #expect(findings.named("link.dmg") == nil)
        #expect(findings.named("Screenshot elsewhere.png") == nil)
    }

    @Test func staleAfterAndNowAreHonoured() async throws {
        let strict = DownloadsScanner(staleAfter: 30 * 86_400)
        let findings = try await collect(strict, context(fs))
        #expect(findings.named("recent.pdf")?.detail == "Downloaded 89 days ago")
        let later = context(fs, now: testNow.addingTimeInterval(86_400))
        #expect(try await collect(scanner, later).named("recent.pdf")?.detail == "Downloaded 90 days ago")
        #expect(DownloadsScanner().staleAfter == 90 * 86_400)
    }

    @Test func missingDownloadsYieldsNothing() async throws {
        let fs: MockFileSystem = ["/Users/test/Desktop/a.dmg": .file(size: 1)]
        #expect(try await collect(scanner, context(fs)).isEmpty)
    }

    @Test func ignoreListIsRespected() async throws {
        let ignore = IgnoreList(paths: [URL(fileURLWithPath: "/Users/test/Downloads/Old Folder")], globs: ["*.dmg"])
        let findings = try await collect(scanner, context(fs, ignore: ignore))
        #expect(findings.named("Old Folder") == nil)
        #expect(findings.named("Fresh.dmg") == nil)
        #expect(findings.named("old.PKG") != nil)
    }
}
