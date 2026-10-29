import Foundation
import Testing
import CleanerCore
@testable import SmartCareModule

private func drain(_ coordinator: SmartCareCoordinator, _ context: ScanContext) async -> [SmartCareEvent] {
    var events: [SmartCareEvent] = []
    for await event in await coordinator.run(context) { events.append(event) }
    return events
}

private func report(_ events: [SmartCareEvent]) -> SmartCareReport? {
    for event in events.reversed() {
        if case .completed(let report) = event { return report }
    }
    return nil
}

@Suite("SmartCareCoordinator")
struct SmartCareCoordinatorTests {
    @Test func runsEveryModuleAndMergesFindings() async throws {
        let coordinator = SmartCareCoordinator(modules: [
            (.cleanup, [FakeCleanupScanner(findings: [finding("/tmp/sc/a", 100), finding("/tmp/sc/b", 50)])]),
            (.clutter, [FakeClutterScanner(findings: [finding("/tmp/sc/big.mov", 4_000, clutterCategory)])]),
            (.performance, [FakePerformanceScanner(findings: [])]),
        ])
        let events = await drain(coordinator, testContext())

        let started = events.compactMap { event -> ModuleID? in
            if case .moduleStarted(let module) = event { return module }
            return nil
        }
        #expect(started == [.cleanup, .clutter, .performance])
        // All starts come before anything else.
        #expect(events.prefix(3).allSatisfy { if case .moduleStarted = $0 { return true } else { return false } })
        guard case .completed = events.last else {
            Issue.record("stream must end with .completed")
            return
        }

        let result = try #require(report(events))
        #expect(result.findings.count == 3)
        #expect(result.summaries[.cleanup]?.totalBytes == 150)
        #expect(result.summaries[.cleanup]?.totalFindings == 2)
        #expect(result.summaries[.clutter]?.totalBytes == 4_000)
        #expect(result.summaries[.performance]?.totalFindings == 0)
        #expect(result.findings(in: .clutter).map(\.path.lastPathComponent) == ["big.mov"])
        #expect(result.failures.isEmpty)

        let finished = events.compactMap { event -> ModuleID? in
            if case .moduleFinished(let module, _) = event { return module }
            return nil
        }
        #expect(Set(finished) == [.cleanup, .clutter, .performance])
        #expect(finished.count == 3)
    }

    @Test func aPathReportedByTwoModulesIsKeptOnce() async throws {
        let shared = "/tmp/sc/Downloads/setup.dmg"
        let coordinator = SmartCareCoordinator(modules: [
            (.cleanup, [FakeCleanupScanner(findings: [finding(shared, 700)])]),
            (.clutter, [FakeClutterScanner(findings: [finding(shared, 700, clutterCategory), finding("/tmp/sc/x", 1, clutterCategory)])]),
        ])
        let result = try #require(report(await drain(coordinator, testContext())))
        #expect(result.findings.count == 2)
        let total = result.summaries.values.reduce(Int64(0)) { $0 + $1.totalBytes }
        #expect(total == 701)
        #expect(result.findings.filter { $0.path.path == shared }.count == 1)
    }

    @Test func protectedPathsAreDroppedAndFailuresRecorded() async throws {
        let coordinator = SmartCareCoordinator(modules: [
            // /usr is protected on macOS and Linux alike.
            (.cleanup, [FakeCleanupScanner(findings: [finding("/usr/lib/cache-x", 9), finding("/tmp/sc/ok", 3)])]),
            (.applications, [FailingScanner()]),
        ])
        let events = await drain(coordinator, testContext(protected: .default))
        let result = try #require(report(events))
        #expect(result.findings.map(\.path.path).sorted() == ["/tmp/sc/apps/one", "/tmp/sc/ok"])
        #expect(result.failures[FailingScanner.id] != nil)
        #expect(events.contains { if case .scannerFailed(.applications, FailingScanner.id, _) = $0 { return true } else { return false } })
        // A failed scanner still counts as done for progress.
        let lastAppsProgress = events.compactMap { event -> Double?? in
            if case .moduleProgress(.applications, let fraction) = event { return fraction }
            return nil
        }.last
        #expect(lastAppsProgress == .some(1.0))
    }

    @Test func cancelStillCompletesWithPartialResults() async throws {
        let coordinator = SmartCareCoordinator(modules: [
            (.cleanup, [FakeCleanupScanner(findings: [finding("/tmp/sc/fast", 10)])]),
            (.clutter, [EndlessScanner()]),
        ])
        let stream = await coordinator.run(testContext())
        var events: [SmartCareEvent] = []
        var clutterFindings = 0
        for await event in stream {
            events.append(event)
            if case .finding(.clutter, _) = event {
                clutterFindings += 1
                if clutterFindings == 5 { await coordinator.cancel() }
            }
        }
        let result = try #require(report(events))
        #expect(result.summaries[.cleanup]?.totalBytes == 10)
        #expect((result.summaries[.clutter]?.totalFindings ?? 0) >= 5)
        #expect(result.summaries[.clutter]?.totalFindings == result.findings(in: .clutter).count)
    }

    @Test func reportRoundTripsThroughJSON() async throws {
        let coordinator = SmartCareCoordinator(modules: [
            (.cleanup, [FakeCleanupScanner(findings: [finding("/tmp/sc/a", 100)])]),
        ])
        let result = try #require(report(await drain(coordinator, testContext())))
        let data = try JSONEncoder().encode(result)
        #expect(try JSONDecoder().decode(SmartCareReport.self, from: data) == result)
    }
}

@Suite("SmartCarePolicy")
struct SmartCarePolicyTests {
    private let report = SmartCareReport(
        startedAt: .now, duration: 1,
        summaries: [:],
        findings: [
            finding("/tmp/p/cache", 100, risk: .safe),
            finding("/tmp/p/app-cache", 30, risk: .caution),
            finding("/tmp/p/lang", 500, risk: .risky),
            finding("/tmp/p/login", 1, perfCategory),
            finding("/tmp/p/movie", 9_000, clutterCategory),
            finding("/tmp/p/orphan", 70, appsCategory),
        ],
        failures: [:])

    @Test func defaultSelectsNonRiskyCleanupAndPerformanceOnly() {
        let policy = SmartCarePolicy.default
        #expect(policy.defaultSelection(report).map(\.path.lastPathComponent) == ["cache", "app-cache", "login"])
        #expect(policy.reclaimableBytes(report) == 131)
        #expect(policy.isReviewOnly(.clutter))
        #expect(policy.isReviewOnly(.applications))
        #expect(policy.isReviewOnly(.protection))
        #expect(!policy.isReviewOnly(.cleanup))
    }

    @Test func riskyIsNeverAutoSelectedEvenWhenAsked() {
        let policy = SmartCarePolicy(autoSelect: [.cleanup: [.safe, .caution, .risky], .applications: [.safe]])
        #expect(!policy.isSelectedByDefault(finding("/tmp/p/lang", 500, risk: .risky)))
        #expect(policy.isSelectedByDefault(finding("/tmp/p/orphan", 70, appsCategory)))
    }
}
