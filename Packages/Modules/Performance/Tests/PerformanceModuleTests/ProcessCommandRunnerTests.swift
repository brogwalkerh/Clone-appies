import Foundation
import Testing
import HelperProtocol
@testable import PerformanceModule

@Suite("ProcessCommandRunner")
struct ProcessCommandRunnerTests {
    let runner = ProcessCommandRunner()

    @Test func runsEchoAndCapturesStdout() async throws {
        let result = try await runner.run(CommandStep(executable: "/bin/echo", arguments: ["hello", "world"]))
        #expect(result.exitCode == 0)
        #expect(result.stdout == "hello world\n")
        #expect(result.stderr == "")
    }

    /// Exercises a nonzero exit and stderr capture. This is a test of the
    /// runner only: the catalog never invokes a shell.
    @Test func reportsNonzeroExitAndStderr() async throws {
        let result = try await runner.run(CommandStep(executable: "/bin/sh", arguments: ["-c", "echo oops >&2; exit 3"]))
        #expect(result.exitCode == 3)
        #expect(result.stdout == "")
        #expect(result.stderr == "oops\n")
    }

    @Test func largeOutputDoesNotDeadlock() async throws {
        let result = try await runner.run(CommandStep(executable: "/bin/sh", arguments: ["-c", "head -c 300000 /dev/zero | tr '\\0' 'x'"]))
        #expect(result.exitCode == 0)
        #expect(result.stdout.count == 300_000)
    }

    @Test func missingExecutableThrows() async {
        await #expect(throws: CommandRunnerError.self) {
            try await runner.run(CommandStep(executable: "/nonexistent/binary", arguments: []))
        }
    }

    @Test func timeoutTerminatesProcess() async throws {
        let quick = ProcessCommandRunner(timeout: 1)
        #expect(quick.timeout == 1)
        #expect(ProcessCommandRunner().timeout == 600)
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: CommandRunnerError.timedOut(executable: "/bin/sleep", seconds: 1)) {
            try await quick.run(CommandStep(executable: "/bin/sleep", arguments: ["30"]))
        }
        #expect(clock.now - start < .seconds(4))
    }

    /// A descendant that inherited the pipes and ignores the kill must not
    /// keep the run waiting. Test of the runner only; the catalog never
    /// invokes a shell.
    @Test func timeoutReturnsWhileADescendantHoldsThePipes() async throws {
        let quick = ProcessCommandRunner(timeout: 1)
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: CommandRunnerError.timedOut(executable: "/bin/sh", seconds: 1)) {
            try await quick.run(CommandStep(executable: "/bin/sh",
                                            arguments: ["-c", "(trap '' TERM; sleep 20) & exec sleep 20"]))
        }
        #expect(clock.now - start < .seconds(8))
    }

    @Test func returnsOutputWhenADescendantOutlivesTheCommand() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await runner.run(CommandStep(executable: "/bin/sh",
                                                      arguments: ["-c", "sleep 20 & echo started; echo warn >&2"]))
        #expect(result.exitCode == 0)
        #expect(result.stdout == "started\n")
        #expect(result.stderr == "warn\n")
        #expect(clock.now - start < .seconds(8))
    }

    /// End-of-file on both pipes long before the exit: the status is still the child's.
    @Test func waitsForExitAfterTheChildClosesItsPipes() async throws {
        let result = try await runner.run(CommandStep(executable: "/bin/sh",
                                                      arguments: ["-c", "echo early; exec >&- 2>&-; sleep 1; exit 7"]))
        #expect(result.exitCode == 7)
        #expect(result.stdout == "early\n")
    }

    @Test func reportsTheTerminatingSignal() async throws {
        let result = try await runner.run(CommandStep(executable: "/bin/sh", arguments: ["-c", "kill -KILL $$"]))
        #expect(result.exitCode == 9)
    }
}
