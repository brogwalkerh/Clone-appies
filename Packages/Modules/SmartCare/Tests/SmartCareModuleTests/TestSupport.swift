import Foundation
import Testing
import CleanerCore
import CleanerCoreTesting
import HelperProtocol
import PerformanceModule
@testable import SmartCareModule

let cleanupCategory = FindingCategory(id: "cleanup.userCaches", displayName: "User Cache Files", module: .cleanup)
let clutterCategory = FindingCategory(id: "clutter.largeFiles", displayName: "Large Files", module: .clutter)
let perfCategory = FindingCategory(id: "performance.brokenLoginItems", displayName: "Broken Login Items", module: .performance)
let appsCategory = FindingCategory(id: "applications.orphaned", displayName: "Orphaned Files", module: .applications)

func finding(_ path: String, _ size: Int64, _ category: FindingCategory = cleanupCategory,
             risk: RiskLevel = .safe, scanner: String = "fake") -> Finding {
    Finding(path: URL(fileURLWithPath: path), sizeBytes: size, category: category, scannerID: scanner, risk: risk)
}

/// A UTC Gregorian calendar with Monday weeks, so week buckets are deterministic.
func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.firstWeekday = 2
    calendar.minimumDaysInFirstWeek = 4
    return calendar
}

func date(_ iso: String) -> Date {
    let formatter = ISO8601DateFormatter()
    return formatter.date(from: iso)!
}

/// Emits fixed findings. Distinct types give distinct static ids.
struct FakeCleanupScanner: CleanerScanner {
    static let id = "fake.cleanup"
    let displayName = "Fake Cleanup"
    let module = ModuleID.cleanup
    let findings: [Finding]
    func scan(_ context: ScanContext) -> AsyncThrowingStream<Finding, any Error> { emit(findings) }
}

struct FakeClutterScanner: CleanerScanner {
    static let id = "fake.clutter"
    let displayName = "Fake Clutter"
    let module = ModuleID.clutter
    let findings: [Finding]
    func scan(_ context: ScanContext) -> AsyncThrowingStream<Finding, any Error> { emit(findings) }
}

struct FakePerformanceScanner: CleanerScanner {
    static let id = "fake.performance"
    let displayName = "Fake Performance"
    let module = ModuleID.performance
    let findings: [Finding]
    func scan(_ context: ScanContext) -> AsyncThrowingStream<Finding, any Error> { emit(findings) }
}

struct FailingScanner: CleanerScanner {
    static let id = "fake.failing"
    let displayName = "Failing"
    let module = ModuleID.applications
    struct Boom: Error, CustomStringConvertible { var description: String { "boom" } }
    func scan(_ context: ScanContext) -> AsyncThrowingStream<Finding, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(finding("/tmp/sc/apps/one", 5, appsCategory, scanner: Self.id))
            continuation.finish(throwing: Boom())
        }
    }
}

/// Yields a finding every few milliseconds until cancelled.
struct EndlessScanner: CleanerScanner {
    static let id = "fake.endless"
    let displayName = "Endless"
    let module = ModuleID.clutter
    func scan(_ context: ScanContext) -> AsyncThrowingStream<Finding, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var index = 0
                while !Task.isCancelled {
                    continuation.yield(finding("/tmp/sc/endless/\(index)", 1, clutterCategory, scanner: Self.id))
                    index += 1
                    try? await Task.sleep(nanoseconds: 2_000_000)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private func emit(_ findings: [Finding]) -> AsyncThrowingStream<Finding, any Error> {
    AsyncThrowingStream { continuation in
        for finding in findings { continuation.yield(finding) }
        continuation.finish()
    }
}

/// Answers every command with exit 0.
struct SucceedingCommandRunner: CommandRunner {
    func run(_ step: CommandStep) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        (0, "", "")
    }
}

func testContext(_ fileSystem: any FileSystem = MockFileSystem(), protected: ProtectedPaths = .none) -> ScanContext {
    ScanContext(fileSystem: fileSystem, home: URL(fileURLWithPath: "/Users/test", isDirectory: true),
                protectedPaths: protected)
}
