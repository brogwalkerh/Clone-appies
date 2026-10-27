import Foundation
import CleanerCore

/// Duplicate files: size bucket -> head+tail FNV-1a 64 prefilter -> full
/// streaming SHA-256 -> group. Each group's *keeper* is the oldest file (ties
/// broken by path); every other member is emitted as a finding.
///
/// The walk only records paths and metadata. Content is read afterwards,
/// bucket by bucket (largest sizes first), one file at a time, so at most one
/// hashing chunk is resident and findings start flowing before the smaller
/// buckets are examined.
public struct DuplicatesScanner: CleanerScanner {
    public static let id = "clutter.duplicates"
    /// Bytes sampled from each end of a file for the prefilter.
    public static let sampleLength = 4_096

    public let displayName = "Duplicate Files"
    public let module = ModuleID.clutter

    public let minSizeBytes: Int64
    public let roots: [String]

    public init(minSizeBytes: Int64 = 1_024, roots: [String] = LargeOldFilesScanner.defaultRoots) {
        self.minSizeBytes = minSizeBytes
        self.roots = roots
    }

    struct Candidate: Sendable, Hashable {
        let url: URL
        let modifiedAt: Date?

        /// Oldest first; files without a date sort last; ties by path.
        static func olderFirst(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
            let l = lhs.modifiedAt ?? .distantFuture
            let r = rhs.modifiedAt ?? .distantFuture
            if l != r { return l < r }
            return lhs.url.path < rhs.url.path
        }
    }

    public func scan(_ context: ScanContext) -> AsyncThrowingStream<Finding, any Error> {
        let minSizeBytes = self.minSizeBytes
        let roots = self.roots
        return makeFindingStream { emitter in
            // Phase 1: metadata only.
            var buckets: [Int64: [Candidate]] = [:]
            try await context.forEachRegularFile(under: context.scanRoots(roots)) { url, attributes in
                guard attributes.sizeBytes >= minSizeBytes else { return }
                buckets[attributes.sizeBytes, default: []].append(Candidate(url: url, modifiedAt: attributes.modifiedAt))
            }

            // Phase 2: hash and emit, one bucket at a time.
            for size in buckets.keys.sorted(by: >) {
                guard let bucket = buckets[size], bucket.count > 1 else { continue }
                buckets[size] = nil
                try Task.checkCancellation()
                for group in try Self.duplicateGroups(in: bucket, size: size, fileSystem: context.fileSystem) {
                    let keeper = group[0]
                    for duplicate in group.dropFirst() {
                        emitter.emit(Finding(path: duplicate.url, sizeBytes: size,
                                             category: ClutterCategory.duplicates, scannerID: Self.id,
                                             risk: .caution, detail: "Duplicate of \(keeper.url.path)",
                                             modifiedAt: duplicate.modifiedAt, isDirectory: false))
                    }
                }
            }
        }
    }

    /// Groups of byte-identical files within one size bucket, each sorted
    /// keeper first; groups ordered by keeper path. Unreadable files are dropped.
    static func duplicateGroups(in bucket: [Candidate], size: Int64,
                                fileSystem: any FileSystem) throws -> [[Candidate]] {
        var byPrefilter: [UInt64: [Candidate]] = [:]
        for candidate in bucket {
            try Task.checkCancellation()
            guard let key = try attempt({ try prefilterHash(of: candidate.url, size: size, fileSystem: fileSystem) })
            else { continue }
            byPrefilter[key, default: []].append(candidate)
        }

        var groups: [[Candidate]] = []
        for survivors in byPrefilter.values where survivors.count > 1 {
            var byDigest: [[UInt8]: [Candidate]] = [:]
            for candidate in survivors {
                try Task.checkCancellation()
                guard let digest = try attempt({ try fileSystem.sha256Digest(of: candidate.url) }) else { continue }
                byDigest[digest, default: []].append(candidate)
            }
            for identical in byDigest.values where identical.count > 1 {
                groups.append(identical.sorted(by: Candidate.olderFirst))
            }
        }
        return groups.sorted { $0[0].url.path < $1[0].url.path }
    }

    /// FNV-1a over the first and last `sampleLength` bytes (the whole file
    /// when it is no longer than both samples together).
    static func prefilterHash(of url: URL, size: Int64, fileSystem: any FileSystem) throws -> UInt64 {
        var hasher = FNV1a64()
        let sample = Int64(sampleLength)
        if size <= 2 * sample {
            hasher.update(try fileSystem.readRange(of: url, offset: 0, length: Int(size)))
        } else {
            hasher.update(try fileSystem.readRange(of: url, offset: 0, length: sampleLength))
            hasher.update(try fileSystem.readRange(of: url, offset: size - sample, length: sampleLength))
        }
        return hasher.value
    }
}
