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

    /// Purgeable space is not a file: a finding at "/" would reach the
    /// remover and count as the ancestor of every other finding.
    @Test func neverYieldsAFinding() async throws {
        let fs: MockFileSystem = ["/Users/test/Documents/a": .file(size: 1)]
        let findings = try await collect(scanner, context(fs))
        #expect(findings.isEmpty)
    }

    @Test func isNotRegisteredAsACleanupScanner() {
        let ids = CleanupScanners.all().map { type(of: $0).id }
        #expect(!ids.contains(PurgeableSpaceScanner.id))
    }

    @Test func noRegisteredScannerYieldsTheVolumeRoot() async throws {
        let fs: MockFileSystem = [
            "/Users/test/Library/Caches/com.example.app/a": .file(size: 1),
            "/Users/test/.Trash/x": .file(size: 1),
        ]
        for registered in CleanupScanners.all() {
            let findings = try await collect(registered, context(fs))
            #expect(!findings.contains { $0.path.standardizedFileURL.path == "/" })
        }
    }

    @Test func probeReportsOnlyPositiveFigures() {
        let bytes = PurgeableSpaceScanner.purgeableBytes()
        #if os(macOS)
        if let bytes { #expect(bytes > 0) }
        #else
        #expect(bytes == nil)
        #endif
    }
}
