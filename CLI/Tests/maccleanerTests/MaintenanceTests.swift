import Foundation
import Testing
import CleanerCore
import HelperProtocol
import PerformanceModule
@testable import maccleaner

/// Records every step it is asked to run and answers with a fixed exit code.
final class FakeCommandRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [CommandStep] = []
    let exitCode: Int32
    let stderr: String

    init(exitCode: Int32 = 0, stderr: String = "") {
        self.exitCode = exitCode
        self.stderr = stderr
    }

    var steps: [CommandStep] { lock.withLock { recorded } }

    func run(_ step: CommandStep) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        lock.withLock { recorded.append(step) }
        return (exitCode, "", stderr)
    }
}

@Suite("Maintenance commands")
struct MaintenanceTests {
    private var userTask: MaintenanceTask {
        MaintenanceCatalog.task(id: "maintenance.clearFontCaches")!
    }
    private var helperTask: MaintenanceTask {
        MaintenanceCatalog.task(id: "maintenance.freeRAM")!
    }
    private let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)

    @Test("catalog listing round-trips through JSON")
    func listJSONRoundTrip() throws {
        let entries = MaintenanceList.entries(MaintenanceCatalog.all)
        #expect(entries.count == MaintenanceCatalog.all.count)
        #expect(entries.contains { $0.id == "maintenance.clearFontCaches" && !$0.requiresHelper && $0.risk == .caution && $0.estimatedSeconds == 10 })
        #expect(entries.contains { $0.id == "maintenance.freeRAM" && $0.requiresHelper })

        let out = BufferSink()
        try MaintenanceList.run(tasks: MaintenanceCatalog.all, json: true, io: CommandIO(out: out, err: BufferSink()))
        let decoded = try ScanJSON.decode([MaintenanceList.Entry].self, from: Data(out.text.utf8))
        #expect(decoded == entries)
        #expect(try ScanJSON.encode(decoded) == out.text)

        // The catalog itself is Codable too.
        let roundTripped = try ScanJSON.decode([MaintenanceTask].self, from: Data(try ScanJSON.encode(MaintenanceCatalog.all).utf8))
        #expect(roundTripped == MaintenanceCatalog.all)
    }

    @Test("catalog listing renders a table")
    func listTable() throws {
        let out = BufferSink()
        try MaintenanceList.run(tasks: [userTask, helperTask], json: false, io: CommandIO(out: out, err: BufferSink()))
        let lines = out.text.split(separator: "\n").map(String.init)
        #expect(lines.count == 4)
        #expect(lines[0].hasPrefix("ID"))
        #expect(lines[0].hasSuffix("Est."))
        #expect(lines[2].hasPrefix("maintenance.clearFontCaches  "))
        #expect(lines[2].contains("  no      caution  "))
        #expect(lines[2].hasSuffix("  10 s"))
        #expect(lines[3].contains("  yes     safe     "))
    }

    @Test("resolves ids in order, drops repeats, rejects unknown ids")
    func resolve() throws {
        let tasks = try MaintenanceRun.resolve(ids: [helperTask.id, userTask.id, helperTask.id], catalog: MaintenanceCatalog.all)
        #expect(tasks.map(\.id) == [helperTask.id, userTask.id])
        #expect(throws: MaintenanceRunError.unknownTask("nope", available: MaintenanceCatalog.all.map(\.id))) {
            try MaintenanceRun.resolve(ids: ["nope"], catalog: MaintenanceCatalog.all)
        }
    }

    @Test("refuses helper tasks by name outside JSON mode")
    func helperRefused() async throws {
        let commands = FakeCommandRunner()
        let runner = MaintenanceRunner(commands: commands, helper: nil, home: home)
        await #expect(throws: MaintenanceRunError.helperRequired([helperTask.id])) {
            _ = try await MaintenanceRun.run(tasks: [userTask, helperTask], runner: runner,
                                             options: MaintenanceRunOptions(),
                                             confirm: { Issue.record("must not prompt"); return false },
                                             io: CommandIO(out: BufferSink(), err: BufferSink()))
        }
        #expect(commands.steps.isEmpty)
    }

    @Test("reports helper tasks as skipped in JSON mode and runs the rest")
    func helperSkippedInJSON() async throws {
        let commands = FakeCommandRunner()
        let runner = MaintenanceRunner(commands: commands, helper: nil, home: home)
        var options = MaintenanceRunOptions()
        options.json = true
        options.assumeYes = true
        let out = BufferSink(), err = BufferSink()
        let outcome = try await MaintenanceRun.run(tasks: [helperTask, userTask], runner: runner, options: options,
                                                   confirm: { false }, io: CommandIO(out: out, err: err))
        #expect(outcome.skippedHelperTasks.map(\.id) == [helperTask.id])
        #expect(outcome.results.map(\.taskID) == [userTask.id])
        #expect(!outcome.aborted)
        #expect(err.lines.first == "[skipped]  maintenance.freeRAM: requires the privileged helper")
        let report = try ScanJSON.decode(MaintenanceRun.Report.self, from: Data(out.text.utf8))
        #expect(report.skipped == [.init(id: helperTask.id, reason: "requires the privileged helper")])
        #expect(report.results == outcome.results)
        #expect(out.lines.count == 1, "stdout must hold only the JSON document")
    }

    @Test("runs a user-level task through the command runner and streams results")
    func userTaskSucceeds() async throws {
        let commands = FakeCommandRunner()
        let runner = MaintenanceRunner(commands: commands, helper: nil, home: home)
        var options = MaintenanceRunOptions()
        options.assumeYes = true
        let out = BufferSink()
        let outcome = try await MaintenanceRun.run(tasks: [userTask], runner: runner, options: options,
                                                   confirm: { Issue.record("--yes must not prompt"); return false },
                                                   io: CommandIO(out: out, err: BufferSink()))
        #expect(outcome.results.count == 1)
        let result = try #require(outcome.results.first)
        #expect(result.succeeded)
        #expect(result.taskID == userTask.id)
        #expect(result.message == "Completed 3 commands")
        #expect(commands.steps == userTask.userSteps)
        #expect(out.lines.first == "Will run 1 task:")
        #expect(out.lines.contains { $0.hasPrefix("[ok]      maintenance.clearFontCaches: Completed 3 commands (") })
        #expect(out.lines.last == "1 of 1 task succeeded.")
    }

    @Test("a failing command is reported as a failed task")
    func userTaskFails() async throws {
        let commands = FakeCommandRunner(exitCode: 3, stderr: "boom")
        let runner = MaintenanceRunner(commands: commands, helper: nil, home: home)
        var options = MaintenanceRunOptions()
        options.assumeYes = true
        let out = BufferSink()
        let outcome = try await MaintenanceRun.run(tasks: [userTask], runner: runner, options: options,
                                                   confirm: { false }, io: CommandIO(out: out, err: BufferSink()))
        let result = try #require(outcome.results.first)
        #expect(!result.succeeded)
        #expect(result.message == "/usr/bin/atsutil exited with status 3: boom")
        #expect(commands.steps.count == 1, "stops at the first failing step")
        #expect(out.lines.last == "0 of 1 task succeeded.")
    }

    @Test("declining the prompt runs nothing")
    func declined() async throws {
        let commands = FakeCommandRunner()
        let runner = MaintenanceRunner(commands: commands, helper: nil, home: home)
        let out = BufferSink()
        let outcome = try await MaintenanceRun.run(tasks: [userTask], runner: runner, options: MaintenanceRunOptions(),
                                                   confirm: { false }, io: CommandIO(out: out, err: BufferSink()))
        #expect(outcome.aborted)
        #expect(outcome.results.isEmpty)
        #expect(commands.steps.isEmpty)
        #expect(out.lines.last == "Aborted.")
    }
}
