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
            "/Users/test/Downloads/linux.ISO",
            "/Users/test/Downloads/undated.dmg",
            "/Users/test/Desktop/Tool.pkg",
            "/Users/test/Documents/Suite.mpkg",
        ])
        #expect(findings.allSatisfy { $0.category.id == "applications.installers" })
        #expect(findings.allSatisfy { $0.category.module == .applications })
        #expect(findings.allSatisfy { $0.scannerID == "applications.installers" })
        #expect(findings.allSatisfy { $0.risk == .caution })
    }

    @Test func ageDetailUsesInjectedNow() async throws {
        let findings = try await collect(scanner, context(fs))
        #expect(findings.named("App.dmg")?.detail == "Installer, 10 days old")
        #expect(findings.named("linux.ISO")?.detail == "Installer, 0 days old")
        #expect(findings.named("Tool.pkg")?.detail == "Installer, 400 days old")
        #expect(findings.named("undated.dmg")?.detail == "Installer")
        let later = try await collect(scanner, context(fs, now: testNow.addingTimeInterval(5 * 86_400)))
        #expect(later.named("App.dmg")?.detail == "Installer, 15 days old")
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
        #expect(findings.paths == ["/Users/test/Downloads/linux.ISO", "/Users/test/Desktop/Tool.pkg", "/Users/test/Documents/Suite.mpkg"])
    }

    @Test func missingRootsYieldNothing() async throws {
        let findings = try await collect(scanner, context(["/Users/test/Movies/a.dmg": .file(size: 1)]))
        #expect(findings.isEmpty)
    }
}
