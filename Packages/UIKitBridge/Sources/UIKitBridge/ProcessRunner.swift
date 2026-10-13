import Foundation

/// Minimal async wrapper over `Foundation.Process` shared by the bridges that
/// shell out (`brew outdated`, `launchctl print`).
///
/// Both pipes are drained on detached tasks *while* the child runs so a large
/// payload can never fill a pipe and deadlock the termination handler. Exit
/// status is returned, not thrown: callers decide what a non-zero status means
/// (`launchctl` uses 113 for "no such service", which is an answer, not an error).
public enum ProcessRunner {
    public struct Output: Sendable {
        public let exitStatus: Int32
        public let stdout: Data
        public let stderr: Data

        public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
        public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
    }

    /// Runs `executable` to completion. Throws only when the process could not
    /// be launched (missing binary, no permission); a non-zero exit is reported
    /// through `Output.exitStatus`.
    public static func run(_ executable: URL,
                           arguments: [String],
                           environment: [String: String]? = nil,
                           capturesStandardError: Bool = false) async throws -> Output {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = capturesStandardError ? stderrPipe : FileHandle.nullDevice
        if let environment {
            process.environment = environment
        }

        // FileHandle is not Sendable in the Darwin overlay; each reader task is
        // the only user of its handle, so hand them over without checking.
        nonisolated(unsafe) let stdoutReader = stdoutPipe.fileHandleForReading
        nonisolated(unsafe) let stderrReader = stderrPipe.fileHandleForReading
        let stdoutDrain = Task.detached(priority: .utility) { () -> Data in
            stdoutReader.readDataToEndOfFile()
        }
        let stderrDrain = Task.detached(priority: .utility) { () -> Data in
            guard capturesStandardError else { return Data() }
            return stderrReader.readDataToEndOfFile()
        }

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                stdoutDrain.cancel()
                stderrDrain.cancel()
                // Close our write ends so the drains return instead of hanging.
                try? stdoutPipe.fileHandleForWriting.close()
                try? stderrPipe.fileHandleForWriting.close()
                continuation.resume(throwing: error)
            }
        }

        let stdout = await stdoutDrain.value
        let stderr = await stderrDrain.value
        return Output(exitStatus: status, stdout: stdout, stderr: stderr)
    }
}
