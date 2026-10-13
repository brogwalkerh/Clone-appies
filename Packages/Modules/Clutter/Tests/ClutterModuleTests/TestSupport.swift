import Foundation
import Testing
import CleanerCore
import CleanerCoreTesting
@testable import ClutterModule

/// Fixed "now" so age-based tests are deterministic.
let testNow = Date(timeIntervalSince1970: 1_760_000_000)

func daysAgo(_ days: Double) -> Date {
    testNow.addingTimeInterval(-days * 86_400)
}

/// Drains a scanner's stream.
func collect(_ scanner: any CleanerScanner, _ context: ScanContext) async throws -> [Finding] {
    var findings: [Finding] = []
    for try await finding in scanner.scan(context) { findings.append(finding) }
    return findings
}

func context(_ fs: MockFileSystem, ignore: IgnoreList = .empty,
             protected: ProtectedPaths = .none, now: Date = testNow) -> ScanContext {
    ScanContext(fileSystem: fs, ignoreList: ignore, protectedPaths: protected, now: now)
}

/// Deterministic pseudo-random bytes (xorshift64), shared with the Python
/// script that produced the reference digests in the hashing tests.
func pseudoRandomData(count: Int, seed: UInt64 = 0x9E37_79B9_7F4A_7C15) -> Data {
    var x = seed
    var bytes = [UInt8](repeating: 0, count: count)
    for i in 0..<count {
        x ^= x &<< 13
        x ^= x &>> 7
        x ^= x &<< 17
        bytes[i] = UInt8(truncatingIfNeeded: x)
    }
    return Data(bytes)
}

/// `count` bytes whose first and last `edge` bytes are zero and whose middle
/// is `fill`, so two such files share head and tail but differ inside.
func paddedData(count: Int, edge: Int, fill: UInt8) -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    for i in edge..<(count - edge) { bytes[i] = fill }
    return Data(bytes)
}

/// Maps image file names to fixed feature vectors; names in `failing` throw,
/// unknown names return nil.
struct StubImageFeatureProvider: ImageFeatureProvider {
    struct Failure: Error {}

    var vectors: [String: [Float]]
    var failing: Set<String> = []

    func featurePrint(for url: URL) async throws -> [Float]? {
        let name = url.lastPathComponent
        if failing.contains(name) { throw Failure() }
        return vectors[name]
    }
}

extension Array where Element == Finding {
    func named(_ lastComponent: String) -> Finding? {
        first { $0.path.lastPathComponent == lastComponent }
    }
    func at(_ path: String) -> Finding? {
        first { $0.path.standardizedFileURL.path == path }
    }
    var paths: Set<String> { Set(map { $0.path.standardizedFileURL.path }) }
    var totalBytes: Int64 { reduce(0) { $0 + $1.sizeBytes } }
}
