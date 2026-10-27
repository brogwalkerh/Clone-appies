import Foundation
import CleanerCore
@testable import maccleaner

/// Deterministic findings shared by the JSON and table tests.
enum Fixtures {
    static let userCaches = FindingCategory(id: "cleanup.userCaches", displayName: "User Cache Files", module: .cleanup)
    static let logs = FindingCategory(id: "cleanup.logs", displayName: "Log Files", module: .cleanup)

    static let modified = Date(timeIntervalSince1970: 1_700_000_000)

    static func uuid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }

    static let findings: [Finding] = [
        Finding(id: uuid(1), path: URL(fileURLWithPath: "/Users/me/Library/Caches/a.db"), sizeBytes: 2_000_000,
                category: userCaches, scannerID: "cleanup.userCaches", risk: .safe,
                detail: "SQLite cache", modifiedAt: modified),
        Finding(id: uuid(2), path: URL(fileURLWithPath: "/Users/me/Library/Logs/x.log"), sizeBytes: 70_000,
                category: logs, scannerID: "cleanup.logs", risk: .risky, detail: nil, modifiedAt: nil),
        Finding(id: uuid(3), path: URL(fileURLWithPath: "/Users/me/Library/Caches/b.db"), sizeBytes: 500_000,
                category: userCaches, scannerID: "cleanup.userCaches", risk: .caution,
                detail: "Forces re-login", modifiedAt: modified),
        Finding(id: uuid(4), path: URL(fileURLWithPath: "/Users/me/Library/Logs/old", isDirectory: true), sizeBytes: 30_000,
                category: logs, scannerID: "cleanup.logs", risk: .safe, detail: nil,
                modifiedAt: modified, isDirectory: true),
    ]

    static let document = ScanDocument(findings: findings, duration: 1.5)
}

/// Test-only scanners for registry filtering.
struct FakeCleanupScanner: CleanerScanner {
    static let id = "test.cleanup"
    var displayName: String { "Fake Cleanup" }
    var module: ModuleID { .cleanup }
    func scan(_ context: ScanContext) -> AsyncThrowingStream<Finding, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

struct FakeClutterScanner: CleanerScanner {
    static let id = "test.clutter"
    var displayName: String { "Fake Clutter" }
    var module: ModuleID { .clutter }
    func scan(_ context: ScanContext) -> AsyncThrowingStream<Finding, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

/// Always fails, for `--strict` behaviour.
struct FailingScanner: CleanerScanner {
    static let id = "test.failing"
    var displayName: String { "Failing" }
    var module: ModuleID { .performance }
    func scan(_ context: ScanContext) -> AsyncThrowingStream<Finding, any Error> {
        AsyncThrowingStream { $0.finish(throwing: CocoaError(.fileReadNoPermission)) }
    }
}
