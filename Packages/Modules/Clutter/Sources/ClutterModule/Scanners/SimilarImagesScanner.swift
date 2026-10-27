import Foundation
import CleanerCore

/// Produces a feature vector for an image. The macOS implementation wraps
/// Vision's `VNGenerateImageFeaturePrintRequest` and lives in UIKitBridge;
/// tests inject a stub.
public protocol ImageFeatureProvider: Sendable {
    /// nil = not an image / unsupported. Throwing skips the file.
    func featurePrint(for url: URL) async throws -> [Float]?
}

/// Similar images: feature prints clustered by cosine distance (single
/// linkage). Each cluster's *keeper* is its largest file; the others are
/// emitted with detail "Similar to <keeper name>".
public struct SimilarImagesScanner: CleanerScanner {
    public static let id = "clutter.similarImages"
    public static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tiff", "gif", "webp", "raw", "dng",
    ]

    public let displayName = "Similar Images"
    public let module = ModuleID.clutter

    public let provider: any ImageFeatureProvider
    public let threshold: Float
    public let roots: [String]

    public init(provider: any ImageFeatureProvider, threshold: Float = 0.25,
                roots: [String] = ["Pictures", "Desktop", "Downloads"]) {
        self.provider = provider
        self.threshold = threshold
        self.roots = roots
    }

    struct Item: Sendable {
        let url: URL
        let sizeBytes: Int64
        let modifiedAt: Date?
        /// Unit-length feature vector.
        let features: [Float]
    }

    public func scan(_ context: ScanContext) -> AsyncThrowingStream<Finding, any Error> {
        let provider = self.provider
        let threshold = self.threshold
        let roots = self.roots
        return makeFindingStream { emitter in
            var items: [Item] = []
            try await context.forEachRegularFile(under: context.scanRoots(roots)) { url, attributes in
                guard Self.imageExtensions.contains(url.pathExtension.lowercased()) else { return }
                let vector: [Float]?
                do {
                    vector = try await provider.featurePrint(for: url)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    return
                }
                guard let vector, let unit = Self.normalized(vector) else { return }
                items.append(Item(url: url, sizeBytes: attributes.sizeBytes,
                                  modifiedAt: attributes.modifiedAt, features: unit))
            }

            for cluster in try Self.clusters(of: items, threshold: threshold) {
                let keeper = cluster[0]
                for other in cluster.dropFirst() {
                    emitter.emit(Finding(path: other.url, sizeBytes: other.sizeBytes,
                                         category: ClutterCategory.similarImages, scannerID: Self.id,
                                         risk: .caution, detail: "Similar to \(keeper.url.lastPathComponent)",
                                         modifiedAt: other.modifiedAt, isDirectory: false))
                }
            }
        }
    }

    /// Single-linkage clusters (union-find over all pairs within `threshold`)
    /// of size > 1, each sorted keeper (largest, then path) first and ordered
    /// by keeper path.
    static func clusters(of items: [Item], threshold: Float) throws -> [[Item]] {
        var parent = Array(0..<items.count)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }
        for i in items.indices {
            try Task.checkCancellation()
            for j in 0..<i where cosineDistance(items[i].features, items[j].features) <= threshold {
                let a = find(i), b = find(j)
                if a != b { parent[max(a, b)] = min(a, b) }
            }
        }
        var members: [Int: [Item]] = [:]
        for i in items.indices {
            members[find(i), default: []].append(items[i])
        }
        return members.values
            .filter { $0.count > 1 }
            .map { $0.sorted(by: largerFirst) }
            .sorted { $0[0].url.path < $1[0].url.path }
    }

    static func largerFirst(_ lhs: Item, _ rhs: Item) -> Bool {
        if lhs.sizeBytes != rhs.sizeBytes { return lhs.sizeBytes > rhs.sizeBytes }
        return lhs.url.path < rhs.url.path
    }

    /// Scales to unit length; nil for empty, zero or non-finite vectors.
    static func normalized(_ vector: [Float]) -> [Float]? {
        guard !vector.isEmpty else { return nil }
        var sum: Float = 0
        for value in vector { sum += value * value }
        guard sum.isFinite, sum > 0 else { return nil }
        let scale = 1 / sum.squareRoot()
        return vector.map { $0 * scale }
    }

    /// 1 - cos(angle) for unit vectors; infinite when dimensions differ.
    static func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return .infinity }
        var dot: Float = 0
        for i in a.indices { dot += a[i] * b[i] }
        return 1 - dot
    }
}
