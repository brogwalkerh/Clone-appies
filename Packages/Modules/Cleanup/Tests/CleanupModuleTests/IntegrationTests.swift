import Foundation
import Testing
import CleanerCore
import CleanerCoreTesting
@testable import CleanupModule

@Suite("Cleanup integration")
struct IntegrationTests {
    @Test func allScannersHaveCleanupModuleAndUniqueIDs() {
        let scanners = CleanupScanners.all()
        #expect(scanners.count == 8)
        let ids = scanners.map { type(of: $0).id }
        #expect(Set(ids).count == ids.count)
        #expect(ids.allSatisfy { $0.hasPrefix("cleanup.") })
        #expect(scanners.allSatisfy { $0.module == .cleanup })
        #expect(scanners.allSatisfy { !$0.displayName.isEmpty })
    }

    @Test func coordinatorRunOverRealFixtureTree() async throws {
        let fixture = try FixtureBuilder(name: "cleanup")
        defer { try? fixture.remove() }
        let old = Date().addingTimeInterval(-95 * 86_400)
        try fixture.build([
            "Library/Caches/com.example.app/Cache.db": .file(size: 2_048),
            "Library/Caches/com.example.app/fsCachedData/blob": .file(size: 1_024),
            "Library/Caches/com.apple.Safari/x": .file(size: 512),
            "Library/Caches/com.apple.bird/sync": .file(size: 4_096),
            "Library/Caches/Homebrew/downloads/a.tar.gz": .file(size: 3_000),
            "Library/Caches/com.apple.dt.Xcode/Downloads/stub": .file(size: 300),
            "Library/Caches/com.apple.dt.Xcode/PredictiveCodeCompletion/model.bin": .file(size: 700),
            "Library/Logs/install.log": .file(size: 100),
            "Library/Logs/com.example.chat/chat.log.1": .file(size: 200),
            "Library/Logs/DiagnosticReports/App.ips": .file(size: 400),
            "Library/Developer/Xcode/DerivedData/App-abc/Build/x.o": .file(size: 5_000),
            "Library/Developer/Xcode/Archives/2026-08-01/App.xcarchive/dSYMs/x": .file(size: 6_000),
            ".Trash/old.png": .file(size: 1_500),
            ".Trash/Folder/a": .file(size: 10),
            "Downloads/Big.pkg.download/Big.pkg": .file(size: 7_000),
            "Downloads/Old.dmg": .file(size: 8_000, modified: old),
            "Downloads/Fresh.dmg": .file(size: 9_000),
            ".ollama/models/blobs/sha256-1": .file(size: 10_000),
            ".cache/huggingface/hub/m/blob": .file(size: 11_000),
            "Documents/Thesis/thesis.pdf": .file(size: 12_000),
            "Desktop/family.jpg": .file(size: 13_000),
        ])

        let context = ScanContext(fileSystem: LocalFileSystem(), home: fixture.root)
        let coordinator = ScanCoordinator(scanners: CleanupScanners.all())
        var findings: [Finding] = []
        var summary: ScanSummary?
        var failures: [String] = []
        for await event in await coordinator.run(context) {
            switch event {
            case .finding(let f): findings.append(f)
            case .completed(let s): summary = s
            case .failed(let id, let message): failures.append("\(id): \(message)")
            default: break
            }
        }

        #expect(failures.isEmpty, "scanner failures: \(failures)")
        let summaryValue = try #require(summary)
        #expect(findings.count > 0)
        #expect(summaryValue.totalFindings == findings.count)
        #expect(summaryValue.totalBytes == findings.totalBytes)
        #expect(summaryValue.byCategory.values.reduce(0, +) == findings.totalBytes)

        let home = fixture.root.path
        let relative = Set(findings.map { String($0.path.standardizedFileURL.path.dropFirst(home.count + 1)) })
        let expected: Set<String> = [
            "Library/Caches/com.example.app",
            "Library/Caches/com.apple.Safari",
            "Library/Caches/Homebrew",
            "Library/Caches/com.apple.dt.Xcode",
            "Library/Logs/install.log",
            "Library/Logs/com.example.chat/chat.log.1",
            "Library/Logs/DiagnosticReports/App.ips",
            "Library/Developer/Xcode/DerivedData/App-abc",
            "Library/Developer/Xcode/Archives/2026-08-01",
            ".Trash/old.png",
            ".Trash/Folder",
            "Downloads/Big.pkg.download",
            "Downloads/Old.dmg",
            ".ollama/models",
            ".cache/huggingface",
        ]
        #expect(relative.isSuperset(of: expected), "missing: \(expected.subtracting(relative))")
        #expect(relative.subtracting(expected).allSatisfy { $0 == "" }, "unexpected: \(relative.subtracting(expected))")
        #expect(!relative.contains { $0.hasPrefix("Documents") || $0.hasPrefix("Desktop") })
        #expect(!relative.contains("Library/Caches/com.apple.bird"))
        #expect(nestedFindings(findings).isEmpty, "nested findings: \(nestedFindings(findings))")

        let byPath = Dictionary(findings.map { (String($0.path.standardizedFileURL.path.dropFirst(home.count + 1)), $0) },
                                uniquingKeysWith: { a, _ in a })
        #expect(byPath["Library/Caches/com.example.app"]?.sizeBytes == 3_072)
        #expect(byPath["Library/Caches/com.apple.Safari"]?.risk == .caution)
        #expect(byPath["Library/Developer/Xcode/Archives/2026-08-01"]?.risk == .risky)
        #expect(byPath["Downloads/Old.dmg"]?.category.id == "cleanup.oldInstallers")
        #expect(byPath[".ollama/models"]?.risk == .risky)
        #expect(summaryValue.byCategory["cleanup.trash"] == 1_510)
    }

    /// Opt-in: set CLEANUP_FIXTURE_HOME to a tree built by Scripts/generate-fixtures.sh.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLEANUP_FIXTURE_HOME"] != nil))
    func generatedFixtureTree() async throws {
        let home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CLEANUP_FIXTURE_HOME"]!, isDirectory: true)
        let context = ScanContext(fileSystem: LocalFileSystem(), home: home)
        let coordinator = ScanCoordinator(scanners: CleanupScanners.all())
        var findings: [Finding] = []
        var summary: ScanSummary?
        for await event in await coordinator.run(context) {
            if case .finding(let f) = event { findings.append(f) }
            if case .completed(let s) = event { summary = s }
        }
        let s = try #require(summary)
        #expect(findings.count > 0)
        #expect(s.totalBytes == findings.totalBytes)
        #expect(nestedFindings(findings).isEmpty, "nested findings: \(nestedFindings(findings))")
        for f in findings.sorted(by: { $0.path.path < $1.path.path }) {
            print("\(f.category.id)\t\(f.risk.rawValue)\t\(ByteFormatter.string(f.sizeBytes))\t\(f.path.path)")
        }
        #expect(!findings.contains { $0.path.path.contains("/Documents/") || $0.path.path.contains("/Desktop/") })
    }
}

/// Paths of findings that lie under another finding's path. Any entry here is
/// a double count in the scan summary.
private func nestedFindings(_ findings: [Finding]) -> [String] {
    let paths = findings.map { $0.path.standardizedFileURL.path }
    return paths.filter { child in
        paths.contains { parent in parent != child && child.hasPrefix(parent + "/") }
    }
}
