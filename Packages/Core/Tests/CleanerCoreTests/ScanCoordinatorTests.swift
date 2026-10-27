import Foundation
import Testing
@testable import CleanerCore
import CleanerCoreTesting

private let category = FindingCategory(id: "test.cat", displayName: "Test", module: .cleanup)
private let otherCategory = FindingCategory(id: "test.other", displayName: "Other", module: .clutter)

private func finding(_ path: String, _ size: Int64, scanner: String, category: FindingCategory = category) -> Finding {
    Finding(path: URL(fileURLWithPath: path), sizeBytes: size, category: category, scannerID: scanner, risk: .safe)
}

struct FakeScannerA: CleanerCore.Scanner {
    static let id = "fake.a"
    let displayName = "Fake A"
    let module = ModuleID.cleanup
    let findings: [Finding]
    func scan(_ context: ScanContext) -> AsyncThrowingStream<Finding, any Error> {
        AsyncThrowingStream { continuation in
            for f in findings { continuation.yield(f) }
            continuation.finish()
        }
    }
}

struct FakeScannerB: CleanerCore.Scanner {
    static let id = "fake.b"
    let displayName = "Fake B"
    let module = ModuleID.clutter
    let findings: [Finding]
    func scan(_ context: ScanContext) -> AsyncThrowingStream<Finding, any Error> {
        AsyncThrowingStream { continuation in
            for f in findings { continuation.yield(f) }
            continuation.finish()
        }
    }
}

struct FailingScanner: CleanerCore.Scanner {
    static let id = "fake.failing"
    let displayName = "Failing"
    let module = ModuleID.cleanup
    struct Boom: Error {}
    func scan(_ context: ScanContext) -> AsyncThrowingStream<Finding, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(finding("/tmp/scan/fail-1", 1, scanner: Self.id))
            continuation.finish(throwing: Boom())
        }
    }
}

/// Yields one finding every few milliseconds, forever, until cancelled.
struct EndlessScanner: CleanerCore.Scanner {
    static let id = "fake.endless"
    let displayName = "Endless"
    let module = ModuleID.cleanup
    func scan(_ context: ScanContext) -> AsyncThrowingStream<Finding, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var i = 0
                while !Task.isCancelled {
                    continuation.yield(finding("/tmp/scan/endless-\(i)", 1, scanner: Self.id))
                    i += 1
                    try? await Task.sleep(for: .milliseconds(5))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@Suite("ScanCoordinator")
struct ScanCoordinatorTests {
    private func context(protected: ProtectedPaths = .none, ignore: IgnoreList = .empty) -> ScanContext {
        let fs: MockFileSystem = ["/tmp/scan": .directory]
        return ScanContext(fileSystem: fs, home: URL(fileURLWithPath: "/Users/test"),
                           ignoreList: ignore, protectedPaths: protected)
    }

    private func collect(_ stream: AsyncStream<ScanEvent>) async -> [ScanEvent] {
        var events: [ScanEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    @Test func dedupesAndSummarizes() async {
        let a = FakeScannerA(findings: [
            finding("/tmp/scan/one", 100, scanner: "fake.a"),
            finding("/tmp/scan/two", 200, scanner: "fake.a"),
            finding("/tmp/scan/./two", 999, scanner: "fake.a"),          // duplicate after standardizing
        ])
        let b = FakeScannerB(findings: [
            finding("/tmp/scan/two/", 200, scanner: "fake.b"),           // duplicate (trailing slash)
            finding("/tmp/scan/three", 300, scanner: "fake.b", category: otherCategory),
        ])
        let coordinator = ScanCoordinator(scanners: [a, b], maxConcurrency: 2)
        let events = await collect(await coordinator.run(context()))

        let findings = events.compactMap { if case .finding(let f) = $0 { return f } else { return nil } }
        #expect(findings.count == 3)
        #expect(Set(findings.map(\.path.standardizedFileURL.path)) == ["/tmp/scan/one", "/tmp/scan/two", "/tmp/scan/three"])

        let started = events.compactMap { if case .started(let id) = $0 { return id } else { return nil } }
        #expect(Set(started) == ["fake.a", "fake.b"])

        let finished = events.compactMap { if case .finished(let id, let count, let bytes) = $0 { return (id, count, bytes) } else { return nil } }
        #expect(finished.count == 2)
        let total = finished.reduce(0) { $0 + $1.1 }
        #expect(total == 3)

        guard case .completed(let summary)? = events.last else {
            Issue.record("last event must be .completed, got \(String(describing: events.last))")
            return
        }
        #expect(summary.totalFindings == 3)
        #expect(summary.totalBytes == 600)
        #expect(summary.byCategory["test.cat"] == 300)
        #expect(summary.byCategory["test.other"] == 300)
        #expect(summary.duration >= 0)
    }

    @Test func filtersProtectedAndIgnored() async {
        let a = FakeScannerA(findings: [
            finding("/usr/lib/libfoo", 100, scanner: "fake.a"),
            finding("/tmp/scan/keep", 200, scanner: "fake.a"),
            finding("/tmp/scan/ignored/file", 300, scanner: "fake.a"),
            finding("/tmp/scan/thing.log", 400, scanner: "fake.a"),
        ])
        let protected = ProtectedPaths(prefixes: [URL(fileURLWithPath: "/usr")])
        let ignore = IgnoreList(paths: [URL(fileURLWithPath: "/tmp/scan/ignored")], globs: ["*.log"])
        let coordinator = ScanCoordinator(scanners: [a])
        let events = await collect(await coordinator.run(context(protected: protected, ignore: ignore)))
        let findings = events.compactMap { if case .finding(let f) = $0 { return f } else { return nil } }
        #expect(findings.map(\.path.path) == ["/tmp/scan/keep"])
        guard case .completed(let summary)? = events.last else {
            Issue.record("missing .completed")
            return
        }
        #expect(summary.totalFindings == 1)
        #expect(summary.totalBytes == 200)
    }

    @Test func reportsFailedScannerAndStillCompletes() async {
        let coordinator = ScanCoordinator(scanners: [FailingScanner(), FakeScannerA(findings: [finding("/tmp/scan/ok", 1, scanner: "fake.a")])])
        let events = await collect(await coordinator.run(context()))
        let failed = events.compactMap { if case .failed(let id, _) = $0 { return id } else { return nil } }
        #expect(failed == ["fake.failing"])
        guard case .completed(let summary)? = events.last else {
            Issue.record("missing .completed")
            return
        }
        // The finding emitted before the failure is kept.
        #expect(summary.totalFindings == 2)
    }

    @Test func honoursConcurrencyBound() async {
        // Many scanners with maxConcurrency 1 must still all run and complete.
        let scanners: [any CleanerCore.Scanner] = (0..<6).map { i in
            FakeScannerA(findings: [finding("/tmp/scan/\(i)", 1, scanner: "fake.a")])
        }
        let coordinator = ScanCoordinator(scanners: scanners, maxConcurrency: 1)
        let events = await collect(await coordinator.run(context()))
        let finished = events.filter { if case .finished = $0 { return true } else { return false } }
        #expect(finished.count == 6)
        guard case .completed(let summary)? = events.last else {
            Issue.record("missing .completed")
            return
        }
        #expect(summary.totalFindings == 6)
    }

    @Test(.timeLimit(.minutes(1))) func cancelStopsEarly() async {
        let coordinator = ScanCoordinator(scanners: [EndlessScanner()])
        let stream = await coordinator.run(context())
        var count = 0
        var sawCompleted = false
        for await event in stream {
            switch event {
            case .finding:
                count += 1
                if count == 3 { await coordinator.cancel() }
            case .completed:
                sawCompleted = true
            default:
                break
            }
        }
        #expect(sawCompleted)
        #expect(count >= 3)
        #expect(count < 1_000)
    }

    @Test func emptyScannerListCompletesImmediately() async {
        let coordinator = ScanCoordinator(scanners: [])
        let events = await collect(await coordinator.run(context()))
        #expect(events.count == 1)
        guard case .completed(let summary)? = events.first else {
            Issue.record("missing .completed")
            return
        }
        #expect(summary.totalFindings == 0)
        #expect(summary.totalBytes == 0)
    }
}
