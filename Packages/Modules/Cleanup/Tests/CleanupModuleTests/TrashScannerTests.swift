import Foundation
import Testing
import CleanerCore
import CleanerCoreTesting
@testable import CleanupModule

@Suite("TrashScanner")
struct TrashScannerTests {
    let scanner = TrashScanner()

    var fs: MockFileSystem {
        [
            "/Users/test/.Trash/old-screenshot.png": .file(size: 3_000, modified: daysAgo(10)),
            "/Users/test/.Trash/Project Backup/archive.tar": .file(size: 25_000),
            "/Users/test/.Trash/Project Backup/notes/a.txt": .file(size: 5),
            "/Users/test/.Trash/App.app": .package,
            "/Users/test/.Trash/App.app/Contents/MacOS/App": .file(size: 900),
            "/Users/test/.Trash/.DS_Store": .file(size: 6_148),
            "/Users/test/.Trash/link": .symlink(to: "/Users/test/Documents"),
        ]
    }

    @Test func topLevelItemsAreFindings() async throws {
        let findings = try await collect(scanner, context(fs))
        #expect(findings.paths == [
            "/Users/test/.Trash/old-screenshot.png",
            "/Users/test/.Trash/Project Backup",
            "/Users/test/.Trash/App.app",
            "/Users/test/.Trash/link",
        ])
        #expect(findings.allSatisfy { $0.category.id == "cleanup.trash" && $0.risk == .safe })
        #expect(findings.first?.category.displayName == "Trash Bins")
        let png = try #require(findings.named("old-screenshot.png"))
        #expect(png.sizeBytes == 3_000)
        #expect(!png.isDirectory)
        #expect(png.modifiedAt == daysAgo(10))
        let backup = try #require(findings.named("Project Backup"))
        #expect(backup.isDirectory)
        #expect(backup.sizeBytes == 25_005)
        #expect(findings.named("App.app")?.sizeBytes == 900)
        #expect(findings.named("link")?.sizeBytes == 0)
        #expect(findings.named("Project Backup/notes") == nil)
    }

    @Test func missingTrashYieldsNothing() async throws {
        let fs: MockFileSystem = ["/Users/test/Documents/a": .file(size: 1)]
        let findings = try await collect(scanner, context(fs))
        #expect(findings.isEmpty)
    }

    @Test func ignoreListIsRespected() async throws {
        let ignore = IgnoreList(globs: ["*.png"])
        let findings = try await collect(scanner, context(fs, ignore: ignore))
        #expect(findings.named("old-screenshot.png") == nil)
        #expect(findings.named("Project Backup") != nil)
    }

    @Test func protectedTrashIsSkipped() async throws {
        let protected = ProtectedPaths(prefixes: [URL(fileURLWithPath: "/Users/test/.Trash")])
        let findings = try await collect(scanner, context(fs, protected: protected))
        #expect(findings.isEmpty)
    }
}
