import Foundation
import Testing
import CleanerCore
import CleanerCoreTesting
@testable import CleanupModule

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
