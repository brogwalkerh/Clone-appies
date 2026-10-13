import Foundation
import Testing
import CleanerCore
import CleanerCoreTesting
@testable import ClutterModule

@Suite("SimilarImagesScanner")
struct SimilarImagesScannerTests {
    let provider = StubImageFeatureProvider(vectors: [
        // Cluster A: three near-identical prints.
        "beach-1.jpg": [1, 0, 0, 0],
        "beach-2.JPG": [0.98, 0.1, 0, 0],
        "beach-3.heic": [0.97, 0, 0.12, 0],
        // Cluster B: two prints.
        "cat-1.png": [0, 1, 0, 0],
        "cat-2.png": [0, 0.95, 0.1, 0.05],
        // Singleton, far from everything.
        "sunset.png": [0, 0, 0, 1],
        // Non-image name carrying an image vector: must be ignored by extension.
        "notes.txt": [1, 0, 0, 0],
        // Degenerate vectors.
        "blank.gif": [0, 0, 0, 0],
        "odd.webp": [1, 0],
    ])

    var fs: MockFileSystem {
        [
            "/Users/test/Pictures/beach-1.jpg": .file(size: 2_000, modified: daysAgo(3)),
            "/Users/test/Pictures/Trip/beach-2.JPG": .file(size: 5_000, modified: daysAgo(2)),
            "/Users/test/Desktop/beach-3.heic": .file(size: 1_000, modified: daysAgo(1)),
            "/Users/test/Pictures/cat-1.png": .file(size: 3_500),
            "/Users/test/Downloads/cat-2.png": .file(size: 3_000),
            "/Users/test/Pictures/sunset.png": .file(size: 9_000),
            "/Users/test/Pictures/notes.txt": .file(size: 50),
            "/Users/test/Pictures/blank.gif": .file(size: 10),
            "/Users/test/Pictures/odd.webp": .file(size: 10),
            "/Users/test/Pictures/unknown.png": .file(size: 10),
            "/Users/test/Documents/beach-1.jpg": .file(size: 99_999),
        ]
    }

    @Test func clustersWithLargestKeeper() async throws {
        let scanner = SimilarImagesScanner(provider: provider, threshold: 0.25)
        let findings = try await collect(scanner, context(fs))
        #expect(findings.paths == [
            "/Users/test/Pictures/beach-1.jpg",
            "/Users/test/Desktop/beach-3.heic",
            "/Users/test/Downloads/cat-2.png",
        ])
        #expect(findings.named("beach-1.jpg")?.detail == "Similar to beach-2.JPG")
        #expect(findings.named("beach-3.heic")?.detail == "Similar to beach-2.JPG")
        #expect(findings.named("cat-2.png")?.detail == "Similar to cat-1.png")
        #expect(findings.named("beach-1.jpg")?.sizeBytes == 2_000)
        #expect(findings.named("beach-1.jpg")?.modifiedAt == daysAgo(3))
        #expect(findings.allSatisfy { $0.risk == .caution && $0.category.id == "clutter.similarImages" })
        #expect(findings.allSatisfy { $0.scannerID == "clutter.similarImages" && !$0.isDirectory })
    }

    @Test func singletonsNonImagesAndDegenerateVectorsAreIgnored() async throws {
        let scanner = SimilarImagesScanner(provider: provider)
        let findings = try await collect(scanner, context(fs))
        #expect(findings.named("sunset.png") == nil)
        #expect(findings.named("notes.txt") == nil)
        #expect(findings.named("blank.gif") == nil)
        #expect(findings.named("odd.webp") == nil)
        #expect(findings.named("unknown.png") == nil)
        #expect(!findings.contains { $0.path.path.hasPrefix("/Users/test/Documents") })
    }

    @Test func providerFailureOnOneFileIsSkipped() async throws {
        var failing = provider
        failing.failing = ["beach-2.JPG"]
        let scanner = SimilarImagesScanner(provider: failing)
        let findings = try await collect(scanner, context(fs))
        // Without beach-2, beach-1 (2 000 bytes) becomes the keeper.
        #expect(findings.named("beach-3.heic")?.detail == "Similar to beach-1.jpg")
        #expect(findings.named("beach-1.jpg") == nil)
        #expect(findings.named("beach-2.JPG") == nil)
        #expect(findings.named("cat-2.png") != nil)
    }

    @Test func thresholdControlsLinkage() async throws {
        let strict = SimilarImagesScanner(provider: provider, threshold: 0.001)
        #expect(try await collect(strict, context(fs)).isEmpty)
        let loose = SimilarImagesScanner(provider: provider, threshold: 1.0)
        let findings = try await collect(loose, context(fs))
        // Everything with a valid 4-vector links into one cluster kept by sunset.png.
        #expect(findings.count == 5)
        #expect(findings.allSatisfy { $0.detail == "Similar to sunset.png" })
    }

    @Test func singleLinkageChainsMergeClusters() throws {
        func item(_ name: String, _ v: [Float]) -> SimilarImagesScanner.Item {
            SimilarImagesScanner.Item(url: URL(fileURLWithPath: "/Users/test/Pictures/\(name)"),
                                      sizeBytes: 1, modifiedAt: nil,
                                      features: SimilarImagesScanner.normalized(v)!)
        }
        // a~b and b~c but a is not within threshold of c.
        let items = [item("a", [1, 0]), item("c", [0, 1]), item("b", [1, 1])]
        let clusters = try SimilarImagesScanner.clusters(of: items, threshold: 0.3)
        #expect(clusters.count == 1)
        #expect(clusters[0].count == 3)
        #expect(SimilarImagesScanner.cosineDistance(items[0].features, items[1].features) == 1)
    }

    @Test func defaultsMatchContract() {
        let scanner = SimilarImagesScanner(provider: provider)
        #expect(scanner.threshold == 0.25)
        #expect(scanner.roots == ["Pictures", "Desktop", "Downloads"])
        #expect(SimilarImagesScanner.id == "clutter.similarImages")
        #expect(scanner.module == .clutter)
    }
}
