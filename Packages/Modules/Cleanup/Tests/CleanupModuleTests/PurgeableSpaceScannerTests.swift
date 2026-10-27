import Foundation
import Testing
import CleanerCore
import CleanerCoreTesting
@testable import CleanupModule

@Suite("PurgeableSpaceScanner")
struct PurgeableSpaceScannerTests {
    let scanner = PurgeableSpaceScanner()

    @Test func metadata() {
        #expect(PurgeableSpaceScanner.id == "cleanup.purgeable")
        #expect(scanner.module == .cleanup)
        #expect(scanner.displayName == "Purgeable Space")
    }

    @Test func findingShapeIsSyntheticRootEntry() async throws {
        let fs: MockFileSystem = ["/Users/test/Documents/a": .file(size: 1)]
        let findings = try await collect(scanner, context(fs))
        #if os(macOS)
        #expect(findings.count <= 1)
        if let finding = findings.first {
            #expect(finding.path.standardizedFileURL.path == "/")
            #expect(!finding.isDirectory)
            #expect(finding.sizeBytes > 0)
            #expect(finding.category.id == "cleanup.purgeable")
            #expect(finding.detail?.hasPrefix("Purgeable space macOS can reclaim") == true)
            #expect(finding.risk == .safe)
        }
        #else
        #expect(findings.isEmpty)
        #endif
    }

    @Test func ignoringRootYieldsNothing() async throws {
        let fs: MockFileSystem = ["/Users/test/Documents/a": .file(size: 1)]
        let ignore = IgnoreList(paths: [URL(fileURLWithPath: "/")])
        let findings = try await collect(scanner, context(fs, ignore: ignore))
        #expect(findings.isEmpty)
    }
}
