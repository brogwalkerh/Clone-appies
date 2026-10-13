import Foundation
import Testing
import CleanerCore
import CleanerCoreTesting
@testable import ClutterModule

@Suite("DuplicatesScanner")
struct DuplicatesScannerTests {
    let scanner = DuplicatesScanner(minSizeBytes: 1_024)
    let blob = pseudoRandomData(count: 20_000)

    var fs: MockFileSystem {
        let edge = DuplicatesScanner.sampleLength
        return [
            // Three identical copies at three ages, nested at different depths.
            "/Users/test/Documents/report.pdf": .data(blob, modified: daysAgo(30)),
            "/Users/test/Documents/Archive/2025/report (1).pdf": .data(blob, modified: daysAgo(300)),
            "/Users/test/Downloads/report copy.pdf": .data(blob, modified: daysAgo(1)),
            // Same size, same head and tail, different middle.
            "/Users/test/Pictures/mid-a.bin": .data(paddedData(count: 3 * edge, edge: edge, fill: 1)),
            "/Users/test/Pictures/mid-b.bin": .data(paddedData(count: 3 * edge, edge: edge, fill: 2)),
            // Same size, entirely different content.
            "/Users/test/Music/x.bin": .data(Data(repeating: 7, count: 2_000)),
            "/Users/test/Music/y.bin": .data(Data(repeating: 8, count: 2_000)),
            // Identical but below minSize.
            "/Users/test/Desktop/tiny-a.txt": .file("tiny"),
            "/Users/test/Desktop/tiny-b.txt": .file("tiny"),
            // Identical but inside a package / outside the roots.
            "/Users/test/Pictures/Lib.photoslibrary": .package,
            "/Users/test/Pictures/Lib.photoslibrary/report.pdf": .data(blob, modified: daysAgo(999)),
            "/Users/test/Library/report.pdf": .data(blob, modified: daysAgo(999)),
        ]
    }

    @Test func identicalFilesAreGroupedWithOldestKeeper() async throws {
        let findings = try await collect(scanner, context(fs))
        let group = findings.filter { $0.detail == "Duplicate of /Users/test/Documents/Archive/2025/report (1).pdf" }
        #expect(group.paths == [
            "/Users/test/Documents/report.pdf",
            "/Users/test/Downloads/report copy.pdf",
        ])
        #expect(findings.named("report (1).pdf") == nil)
        #expect(group.allSatisfy { $0.sizeBytes == 20_000 && $0.risk == .caution && !$0.isDirectory })
        #expect(group.allSatisfy { $0.category.id == "clutter.duplicates" && $0.scannerID == "clutter.duplicates" })
        #expect(findings.named("report copy.pdf")?.modifiedAt == daysAgo(1))
    }

    @Test func sameHeadAndTailButDifferentMiddleIsNotGrouped() async throws {
        let findings = try await collect(scanner, context(fs))
        #expect(findings.named("mid-a.bin") == nil)
        #expect(findings.named("mid-b.bin") == nil)
        #expect(findings.named("x.bin") == nil)
        #expect(findings.named("y.bin") == nil)
    }

    @Test func minSizePackagesAndRootsAreRespected() async throws {
        let findings = try await collect(scanner, context(fs))
        #expect(findings.count == 2)
        #expect(findings.named("tiny-a.txt") == nil && findings.named("tiny-b.txt") == nil)
        #expect(!findings.contains { $0.path.path.contains("photoslibrary") || $0.path.path.contains("/Library/") })

        let small = DuplicatesScanner(minSizeBytes: 4)
        let withTiny = try await collect(small, context(fs))
        #expect(withTiny.named("tiny-b.txt")?.detail == "Duplicate of /Users/test/Desktop/tiny-a.txt")
    }

    @Test func keeperTieBreaksByPathAndUndatedSortsLast() async throws {
        let fs: MockFileSystem = [
            "/Users/test/Documents/b.bin": .data(blob, modified: daysAgo(10)),
            "/Users/test/Documents/a.bin": .data(blob, modified: daysAgo(10)),
            "/Users/test/Documents/undated.bin": .data(blob),
        ]
        let findings = try await collect(scanner, context(fs))
        #expect(findings.paths == ["/Users/test/Documents/b.bin", "/Users/test/Documents/undated.bin"])
        #expect(findings.allSatisfy { $0.detail == "Duplicate of /Users/test/Documents/a.bin" })
    }

    @Test func ignoredFilesNeverTakePartInGroups() async throws {
        let ignore = IgnoreList(paths: [URL(fileURLWithPath: "/Users/test/Documents/Archive")])
        let findings = try await collect(scanner, context(fs, ignore: ignore))
        #expect(findings.paths == ["/Users/test/Downloads/report copy.pdf"])
        #expect(findings.first?.detail == "Duplicate of /Users/test/Documents/report.pdf")
    }

    @Test func largerBucketsAreEmittedFirst() async throws {
        let big = pseudoRandomData(count: 50_000, seed: 42)
        let fs: MockFileSystem = [
            "/Users/test/Documents/small-1": .data(blob, modified: daysAgo(2)),
            "/Users/test/Documents/small-2": .data(blob, modified: daysAgo(1)),
            "/Users/test/Documents/big-1": .data(big, modified: daysAgo(2)),
            "/Users/test/Documents/big-2": .data(big, modified: daysAgo(1)),
        ]
        let findings = try await collect(scanner, context(fs))
        #expect(findings.map(\.path.lastPathComponent) == ["big-2", "small-2"])
    }

    @Test func equalLogicalSizeWithDifferentAllocatedSizeIsGrouped() async throws {
        // Byte-identical content; APFS compression / clonefile makes the
        // on-disk footprint differ. They must land in the same bucket.
        let fs: MockFileSystem = [
            "/Users/test/Documents/original.bin": .data(blob, allocatedSize: 24_576, modified: daysAgo(40)),
            "/Users/test/Documents/compressed.bin": .data(blob, allocatedSize: 8_192, modified: daysAgo(3)),
            "/Users/test/Documents/cloned.bin": .data(blob, allocatedSize: 0, modified: daysAgo(1)),
        ]
        let findings = try await collect(scanner, context(fs))
        #expect(findings.paths == [
            "/Users/test/Documents/compressed.bin",
            "/Users/test/Documents/cloned.bin",
        ])
        #expect(findings.allSatisfy { $0.detail == "Duplicate of /Users/test/Documents/original.bin" })
        // Findings report the allocated size, so reclaim figures stay accurate.
        #expect(findings.named("compressed.bin")?.sizeBytes == 8_192)
        #expect(findings.named("cloned.bin")?.sizeBytes == 0)
    }

    @Test func minimumSizeGateUsesLogicalSize() async throws {
        // Logically large files whose on-disk footprint is below `minSizeBytes`
        // (sparse, cloned, or heavily compressed) are still candidates.
        let fs: MockFileSystem = [
            "/Users/test/Documents/sparse-a.bin": .data(blob, allocatedSize: 512, modified: daysAgo(2)),
            "/Users/test/Documents/sparse-b.bin": .data(blob, allocatedSize: 512, modified: daysAgo(1)),
        ]
        let findings = try await collect(scanner, context(fs))
        #expect(findings.paths == ["/Users/test/Documents/sparse-b.bin"])
        #expect(findings.first?.sizeBytes == 512)
    }

    @Test func prefilterTailOffsetIsTakenFromLogicalSize() throws {
        let edge = DuplicatesScanner.sampleLength
        let a = pseudoRandomData(count: 3 * edge, seed: 11)
        var b = a
        b[b.count - 1] ^= 0xFF  // differs only in the last byte
        let allocated = Int64(8 * edge)
        let fs: MockFileSystem = [
            "/Users/test/a.bin": .data(a, allocatedSize: allocated),
            "/Users/test/b.bin": .data(b, allocatedSize: allocated),
        ]
        let urlA = URL(fileURLWithPath: "/Users/test/a.bin")
        let urlB = URL(fileURLWithPath: "/Users/test/b.bin")
        let logical = Int64(a.count)
        #expect(try DuplicatesScanner.prefilterHash(of: urlA, size: logical, fileSystem: fs)
                != DuplicatesScanner.prefilterHash(of: urlB, size: logical, fileSystem: fs))
        // An offset derived from the allocated size would read past EOF and
        // sample an empty tail, hiding the difference from the prefilter.
        #expect(try DuplicatesScanner.prefilterHash(of: urlA, size: allocated, fileSystem: fs)
                == DuplicatesScanner.prefilterHash(of: urlB, size: allocated, fileSystem: fs))
    }

    @Test func realFilesAreHashedThroughFileHandles() async throws {
        let fixture = try FixtureBuilder(name: "clutter-dups")
        defer { try? fixture.remove() }
        let data = pseudoRandomData(count: 3_000_000, seed: 7)
        var altered = data
        altered[1_500_000] ^= 0xFF
        try fixture.file("Documents/one.bin", contents: data, modified: daysAgo(5))
        try fixture.file("Documents/Sub/two.bin", contents: data, modified: daysAgo(50))
        try fixture.file("Pictures/three.bin", contents: altered, modified: daysAgo(500))
        let context = ScanContext(fileSystem: LocalFileSystem(), home: fixture.root, now: testNow)
        let findings = try await collect(scanner, context)
        #expect(findings.map(\.path.lastPathComponent) == ["one.bin"])
        #expect(findings.first?.detail == "Duplicate of \(fixture.url("Documents/Sub/two.bin").standardizedFileURL.path)")
        #expect(findings.first?.sizeBytes == 3_000_000)
    }

    @Test func defaultsMatchContract() {
        let scanner = DuplicatesScanner()
        #expect(scanner.minSizeBytes == 1_024)
        #expect(scanner.roots == LargeOldFilesScanner.defaultRoots)
        #expect(DuplicatesScanner.id == "clutter.duplicates")
        #expect(scanner.module == .clutter)
    }
}
