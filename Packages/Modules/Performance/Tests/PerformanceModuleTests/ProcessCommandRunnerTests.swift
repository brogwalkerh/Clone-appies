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
}
