import Foundation
import Testing
import CleanerCore
import HelperProtocol
@testable import PerformanceModule

@Suite("MaintenanceRunner")
struct MaintenanceRunnerTests {
    let flushDNS = MaintenanceCatalog.task(id: "maintenance.flushDNS")!
    let periodic = MaintenanceCatalog.task(id: "maintenance.runPeriodic")!
    let thin = MaintenanceCatalog.task(id: "maintenance.thinSnapshots")!
    let fonts = MaintenanceCatalog.task(id: "maintenance.clearFontCaches")!

    func makeRunner(commands: FakeCommandRunner = FakeCommandRunner(), helper: FakeHelper?) -> MaintenanceRunner {
        MaintenanceRunner(commands: commands, helper: helper, home: testHome)
    }

    // MARK: Helper tasks

    @Test func helperTaskSucceeds() async {
        let helper = FakeHelper()
        helper.set(.flushDNSCache, message: "DNS cache flushed")
        let result = await makeRunner(helper: helper).run(flushDNS)
        #expect(result.taskID == "maintenance.flushDNS")
        #expect(result.succeeded)
        #expect(result.message == "DNS cache flushed")
        #expect(result.bytesReclaimed == nil)
        #expect(result.duration >= 0)
        #expect(helper.operations == [.flushDNSCache])
    }

    @Test func helperTaskReportsFailureMessage() async {
        let helper = FakeHelper()
        helper.set(.flushDNSCache, succeeded: false, message: "mDNSResponder not running")
        let result = await makeRunner(helper: helper).run(flushDNS)
        #expect(!result.succeeded)
        #expect(result.message == "mDNSResponder not running")
    }

    @Test func helperTaskReportsThrownError() async {
        let helper = FakeHelper()
        helper.error = TestError(description: "XPC connection interrupted")
        let result = await makeRunner(helper: helper).run(flushDNS)
        #expect(!result.succeeded)
        #expect(result.message.contains("XPC connection interrupted"))
    }

    @Test func missingHelperFailsFast() async {
        let commands = FakeCommandRunner()
        let result = await makeRunner(commands: commands, helper: nil).run(flushDNS)
        #expect(!result.succeeded)
        #expect(result.message == "Privileged helper not installed")
        #expect(commands.steps.isEmpty)
    }

    @Test func multiOperationTaskRunsAllInOrderAndAggregatesBytes() async {
        let helper = FakeHelper()
        helper.set(.runPeriodicScripts(.daily), message: "daily", bytesReclaimed: 100)
        helper.set(.runPeriodicScripts(.weekly), message: "weekly", bytesReclaimed: nil)
        helper.set(.runPeriodicScripts(.monthly), message: "monthly", bytesReclaimed: 250)
        let result = await makeRunner(helper: helper).run(periodic)
        #expect(result.succeeded)
        #expect(result.bytesReclaimed == 350)
        #expect(result.message == "daily; weekly; monthly")
        #expect(helper.operations == [
            .runPeriodicScripts(.daily), .runPeriodicScripts(.weekly), .runPeriodicScripts(.monthly),
        ])
    }

    @Test func multiOperationTaskStopsAtFirstFailure() async {
        let helper = FakeHelper()
        helper.set(.runPeriodicScripts(.daily), bytesReclaimed: 40)
        helper.set(.runPeriodicScripts(.weekly), succeeded: false, message: "weekly broke")
        let result = await makeRunner(helper: helper).run(periodic)
        #expect(!result.succeeded)
        #expect(result.message == "weekly broke")
        #expect(result.bytesReclaimed == 40)
        #expect(helper.operations == [.runPeriodicScripts(.daily), .runPeriodicScripts(.weekly)])
    }

    @Test func bytesReclaimedPassThrough() async {
        let helper = FakeHelper()
        helper.set(.thinLocalSnapshots(bytesToFree: 10_000_000_000), message: "", bytesReclaimed: 9_500_000_000)
        let result = await makeRunner(helper: helper).run(thin)
        #expect(result.succeeded)
        #expect(result.bytesReclaimed == 9_500_000_000)
        #expect(result.message == "Completed")
    }

    // MARK: User-level tasks

    @Test func userTaskRunsEachStepInOrder() async {
        let commands = FakeCommandRunner()
        let helper = FakeHelper()
        let result = await makeRunner(commands: commands, helper: helper).run(fonts)
        #expect(result.succeeded)
        #expect(result.message == "Completed 3 commands")
        #expect(commands.steps == fonts.userSteps)
        #expect(helper.operations.isEmpty)
    }

    @Test func userTaskRunsWithoutHelper() async {
        let commands = FakeCommandRunner()
        let result = await makeRunner(commands: commands, helper: nil).run(fonts)
        #expect(result.succeeded)
        #expect(commands.steps.count == 3)
    }

    @Test func userTaskStopsAtFirstFailingStepWithStderr() async {
        let commands = FakeCommandRunner()
        commands.set(fonts.userSteps[1], exitCode: 2, stderr: "  server not running\n")
        let result = await makeRunner(commands: commands, helper: nil).run(fonts)
        #expect(!result.succeeded)
        #expect(result.message == "/usr/bin/atsutil exited with status 2: server not running")
        #expect(commands.steps == Array(fonts.userSteps.prefix(2)))
    }

    @Test func userTaskFailureWithoutStderr() async {
        let commands = FakeCommandRunner()
        commands.set(fonts.userSteps[0], exitCode: 1)
        let result = await makeRunner(commands: commands, helper: nil).run(fonts)
        #expect(result.message == "/usr/bin/atsutil exited with status 1")
        #expect(commands.steps.count == 1)
    }

    @Test func userTaskReportsLaunchError() async {
        let commands = FakeCommandRunner()
        commands.error = TestError(description: "no such file")
        let result = await makeRunner(commands: commands, helper: nil).run(fonts)
        #expect(!result.succeeded)
        #expect(result.message == "Could not run /usr/bin/atsutil: no such file")
    }

    @Test func userStepsExpandTildeAgainstHome() async {
        let commands = FakeCommandRunner()
        let task = MaintenanceTask(id: "t.home", name: "Home", summary: "s", detail: "d", requiresHelper: false,
                                   helperOperation: nil, risk: .safe, estimatedSeconds: 1,
                                   userSteps: [CommandStep(executable: "/bin/ls", arguments: ["~/Library", "~", "~x", "/tmp"])])
        let result = await makeRunner(commands: commands, helper: nil).run(task)
        #expect(result.succeeded)
        #expect(commands.steps == [CommandStep(executable: "/bin/ls",
                                               arguments: ["/Users/test/Library", "/Users/test", "~x", "/tmp"])])
    }

    @Test func emptyTasksFail() async {
        let runner = makeRunner(helper: FakeHelper())
        let noSteps = MaintenanceTask(id: "t.empty", name: "E", summary: "s", detail: "d", requiresHelper: false,
                                      helperOperation: nil, risk: .safe, estimatedSeconds: 1)
        let noOperation = MaintenanceTask(id: "t.noop", name: "E", summary: "s", detail: "d", requiresHelper: true,
                                          helperOperation: nil, risk: .safe, estimatedSeconds: 1)
        #expect(await runner.run(noSteps).succeeded == false)
        #expect(await runner.run(noOperation).succeeded == false)
    }

    // MARK: Streaming and ordering

    @Test func streamYieldsResultsInOrderAndSequentially() async {
        let log = EventLog()
        let helper = FakeHelper(log: log, delayNanoseconds: 5_000_000)
        helper.set(.flushDNSCache, bytesReclaimed: 1)
        let commands = FakeCommandRunner(log: log, delayNanoseconds: 5_000_000)
        let runner = makeRunner(commands: commands, helper: helper)
        var results: [MaintenanceResult] = []
        for await result in await runner.run([flushDNS, fonts, thin, periodic]) {
            results.append(result)
        }
        #expect(results.map(\.taskID) == [
            "maintenance.flushDNS", "maintenance.clearFontCaches", "maintenance.thinSnapshots", "maintenance.runPeriodic",
        ])
        #expect(results.allSatisfy { $0.succeeded })
        #expect(results.map(\.bytesReclaimed) == [1, nil, nil, nil])
        expectNoInterleaving(log.all)
        let expectedEntries = 2 * (1 + 3 + 1 + 3)
        #expect(log.all.count == expectedEntries)
    }

    @Test func concurrentCallsNeverOverlap() async {
        let log = EventLog()
        let helper = FakeHelper(log: log, delayNanoseconds: 10_000_000)
        let commands = FakeCommandRunner(log: log, delayNanoseconds: 10_000_000)
        let runner = makeRunner(commands: commands, helper: helper)
        async let a = runner.run(periodic)
        async let b = runner.run(fonts)
        async let c = runner.run(flushDNS)
        let results = await [a, b, c]
        #expect(results.allSatisfy { $0.succeeded })
        #expect(results.map(\.taskID) == ["maintenance.runPeriodic", "maintenance.clearFontCaches", "maintenance.flushDNS"])
        let entries = log.all
        let expectedEntries = 2 * (3 + 3 + 1)
        #expect(entries.count == expectedEntries)
        expectNoInterleaving(entries)
        // Steps of one task stay together.
        let starts = entries.filter { $0.hasPrefix("start ") }.map { String($0.dropFirst(6)) }
        let grouped = [
            ["periodic.daily", "periodic.weekly", "periodic.monthly"],
            ["/usr/bin/atsutil databases -removeUser", "/usr/bin/atsutil server -shutdown", "/usr/bin/atsutil server -ping"],
            ["flushDNSCache"],
        ]
        #expect(grouped.contains { starts.starts(with: $0) })
        for group in grouped {
            guard let index = starts.firstIndex(of: group[0]) else {
                Issue.record("missing \(group[0])")
                continue
            }
            #expect(Array(starts[index..<min(starts.count, index + group.count)]) == group)
        }
    }

    @Test func emptyStreamCompletes() async {
        let runner = makeRunner(helper: nil)
        var count = 0
        for await _ in await runner.run([]) { count += 1 }
        #expect(count == 0)
    }

    private func expectNoInterleaving(_ entries: [String]) {
        var index = 0
        while index < entries.count {
            let entry = entries[index]
            guard entry.hasPrefix("start ") else {
                Issue.record("expected a start entry at \(index), found \(entry)")
                return
            }
            let expectedEnd = "end " + entry.dropFirst(6)
            guard index + 1 < entries.count, entries[index + 1] == expectedEnd else {
                Issue.record("\(entry) was interleaved: \(entries)")
                return
            }
            index += 2
        }
    }
}
