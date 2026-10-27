import Foundation
import Testing
import CleanerCore
import CleanerCoreTesting
@testable import ClutterModule

@Suite("Clutter integration")
struct IntegrationTests {
    @Test func scannerListMatchesContract() {
        let scanners = ClutterScanners.all()
        #expect(scanners.map { type(of: $0).id } == ["clutter.largeOld", "clutter.duplicates", "clutter.downloads"])
        #expect(scanners.allSatisfy { $0.module == .clutter && !$0.displayName.isEmpty })

        let withImages = ClutterScanners.all(imageFeatures: StubImageFeatureProvider(vectors: [:]))
        #expect(withImages.map { type(of: $0).id } == [
            "clutter.largeOld", "clutter.duplicates", "clutter.downloads", "clutter.similarImages",
        ])
    }

    @Test func coordinatorRunOverRealFixtureTree() async throws {
        let fixture = try FixtureBuilder(name: "clutter")
        defer { try? fixture.remove() }
        let old = Date().addingTimeInterval(-200 * 86_400)
        let blob = pseudoRandomData(count: 8_192, seed: 11)
        try fixture.build([
            "Documents/thesis.pdf": .data(blob, modified: old),
            "Documents/Backup/thesis.pdf": .data(blob),
            "Pictures/thesis copy.pdf": .data(blob),
            "Documents/notes.txt": .file(size: 2_048, modified: old),
            "Documents/fresh.txt": .file(size: 3_000),
            "Desktop/unique.bin": .data(pseudoRandomData(count: 4_096, seed: 12)),
            "Downloads/App.dmg": .file(size: 10_000),
            "Downloads/Screenshot 2026-01-01.png": .file(size: 300),
            "Downloads/stale.csv": .file(size: 700, modified: old),
            "Downloads/recent.csv": .file(size: 700),
            "Movies/clip.mov": .file(size: 50_000),
            "Library/Caches/ignored.bin": .data(blob),
        ])

        let provider = StubImageFeatureProvider(vectors: ["Screenshot 2026-01-01.png": [1, 0]])
        let context = ScanContext(fileSystem: LocalFileSystem(), home: fixture.root)
        let coordinator = ScanCoordinator(scanners: ClutterScanners.all(imageFeatures: provider))
        var findings: [Finding] = []
        var summary: ScanSummary?
        var failures: [String] = []
        var finished: Set<String> = []
        for await event in await coordinator.run(context) {
            switch event {
            case .finding(let f): findings.append(f)
            case .completed(let s): summary = s
            case .failed(let id, let message): failures.append("\(id): \(message)")
            case .finished(let id, _, _): finished.insert(id)
            default: break
            }
        }

        #expect(failures.isEmpty, "scanner failures: \(failures)")
        #expect(finished == ["clutter.largeOld", "clutter.duplicates", "clutter.downloads", "clutter.similarImages"])
        let summaryValue = try #require(summary)
        #expect(summaryValue.totalFindings == findings.count)
        #expect(summaryValue.totalBytes == findings.totalBytes)
        #expect(summaryValue.byCategory.values.reduce(0, +) == findings.totalBytes)
        #expect(nestedFindings(findings).isEmpty, "nested findings: \(nestedFindings(findings))")

        let home = fixture.root.path
        let byPath = Dictionary(findings.map { (String($0.path.standardizedFileURL.path.dropFirst(home.count + 1)), $0) },
                                uniquingKeysWith: { a, _ in a })
        #expect(Set(byPath.keys) == [
            "Documents/thesis.pdf",
            "Documents/Backup/thesis.pdf",
            "Pictures/thesis copy.pdf",
            "Documents/notes.txt",
            "Downloads/App.dmg",
            "Downloads/Screenshot 2026-01-01.png",
            "Downloads/stale.csv",
        ], "got: \(byPath.keys.sorted())")
        // thesis.pdf is both old and the duplicate keeper: one finding, first scanner wins.
        #expect(byPath["Documents/thesis.pdf"]?.category.id == "clutter.oldFiles")
        #expect(byPath["Documents/Backup/thesis.pdf"]?.category.id == "clutter.duplicates")
        #expect(byPath["Documents/Backup/thesis.pdf"]?.detail == "Duplicate of \(fixture.url("Documents/thesis.pdf").standardizedFileURL.path)")
        #expect(byPath["Downloads/App.dmg"]?.detail == "Installer")
        #expect(byPath["Downloads/stale.csv"]?.detail?.hasPrefix("Downloaded 200 days ago") == true)
        #expect(summaryValue.byCategory["clutter.duplicates"] == 16_384)
        #expect(findings.allSatisfy { $0.risk == .caution })
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
