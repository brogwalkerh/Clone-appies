import Foundation
import Testing
import CleanerCore
import CleanerCoreTesting
@testable import ApplicationsModule

@Suite("InstallersScanner")
struct InstallersScannerTests {
    let scanner = InstallersScanner()

    var fs: MockFileSystem {
        [
            "/Users/test/Downloads/App.dmg": .file(size: 50_000, modified: daysAgo(10)),
            "/Users/test/Downloads/linux.ISO": .file(size: 70_000, modified: daysAgo(0.5)),
            "/Users/test/Downloads/undated.dmg": .file(size: 10),
            "/Users/test/Downloads/archive.zip": .file(size: 20, modified: daysAgo(10)),
            "/Users/test/Downloads/nested/Deep.dmg": .file(size: 30, modified: daysAgo(10)),
            "/Users/test/Downloads/link.dmg": .symlink(to: "/Users/test/Downloads/App.dmg"),
            "/Users/test/Desktop/Tool.pkg": .file(size: 40_000, modified: daysAgo(400)),
            "/Users/test/Documents/Suite.mpkg": .package(modified: daysAgo(2)),
            "/Users/test/Documents/Suite.mpkg/Contents/Packages/a.pkg": .file(size: 1_000),
            "/Users/test/Documents/Suite.mpkg/Contents/distribution.dist": .file(size: 200),
            "/Users/test/Documents/report.pdf": .file(size: 5),
            "/Users/test/Movies/old.dmg": .file(size: 5, modified: daysAgo(10)),
        ]
    }

    @Test func findsInstallersTopLevelOnly() async throws {
        let findings = try await collect(scanner, context(fs))
        #expect(findings.paths == [
            "/Users/test/Downloads/App.dmg",
            "/Users/test/Downloads/undated.dmg",
            "/Users/test/Desktop/Tool.pkg",
            "/Users/test/Documents/Suite.mpkg",
        ])
        #expect(findings.allSatisfy { $0.category.id == "applications.installers" })
        #expect(findings.allSatisfy { $0.category.module == .applications })
        #expect(findings.allSatisfy { $0.scannerID == "applications.installers" })
        // `.iso` images are not app installers.
        #expect(findings.named("linux.ISO") == nil)
    }

    /// Only Downloads may be pre-selected; a disk image filed under Desktop
    /// or Documents (an encrypted vault, an archived installer) is review-only.
    @Test func onlyDownloadsIsPreselectable() async throws {
        let tree: MockFileSystem = [
            "/Users/test/Downloads/App.dmg": .file(size: 1, modified: daysAgo(10)),
            "/Users/test/Documents/Vault.dmg": .file(size: 9_000, modified: daysAgo(700)),
            "/Users/test/Documents/Fresh.dmg": .file(size: 9_000, modified: daysAgo(0)),
            "/Users/test/Desktop/Tool.pkg": .file(size: 1, modified: daysAgo(400)),
            "/Users/test/Documents/backup.iso": .file(size: 1, modified: daysAgo(400)),
        ]
        let findings = try await collect(scanner, context(tree))
        #expect(findings.named("App.dmg")?.risk == .caution)
        #expect(findings.named("Vault.dmg")?.risk == .risky)
        #expect(findings.named("Fresh.dmg")?.risk == .risky)
        #expect(findings.named("Tool.pkg")?.risk == .risky)
        #expect(findings.named("backup.iso") == nil)
        #expect(findings.named("Vault.dmg")?.detail == "Disk image or installer package, modified 700 days ago")
    }

    @Test func ageDetailUsesInjectedNow() async throws {
        let findings = try await collect(scanner, context(fs))
        #expect(findings.named("App.dmg")?.detail == "Installer, modified 10 days ago")
        #expect(findings.named("Tool.pkg")?.detail == "Disk image or installer package, modified 400 days ago")
        #expect(findings.named("undated.dmg")?.detail == "Installer")
        let later = try await collect(scanner, context(fs, now: testNow.addingTimeInterval(5 * 86_400)))
        #expect(later.named("App.dmg")?.detail == "Installer, modified 15 days ago")
    }

    @Test func packagesAreSizedAsDirectories() async throws {
        let findings = try await collect(scanner, context(fs))
        let suite = try #require(findings.named("Suite.mpkg"))
        #expect(suite.isDirectory)
        #expect(suite.sizeBytes == 1_200)
        #expect(suite.modifiedAt == daysAgo(2))
        #expect(findings.named("App.dmg")?.sizeBytes == 50_000)
        #expect(findings.named("App.dmg")?.isDirectory == false)
    }

    @Test func ignoreListIsRespected() async throws {
        let findings = try await collect(scanner, context(fs, ignore: IgnoreList(globs: ["*.dmg"])))
        #expect(findings.paths == ["/Users/test/Desktop/Tool.pkg", "/Users/test/Documents/Suite.mpkg"])
    }

    @Test func missingRootsYieldNothing() async throws {
        let findings = try await collect(scanner, context(["/Users/test/Movies/a.dmg": .file(size: 1)]))
        #expect(findings.isEmpty)
    }
}
