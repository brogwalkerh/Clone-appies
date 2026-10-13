import Foundation
import HelperProtocol

public enum CommandRunnerError: Error, Sendable, Hashable, CustomStringConvertible {
    case launchFailed(executable: String, reason: String)
    case timedOut(executable: String, seconds: Int)

    public var description: String {
        switch self {
        case .launchFailed(let executable, let reason):
            return "Could not launch \(executable): \(reason)"
        case .timedOut(let executable, let seconds):
            return "\(executable) did not finish within \(seconds) seconds and was terminated"
        }
    }
}

/// `CommandRunner` backed by `Foundation.Process`. Never involves a shell:
/// the executable and arguments are passed exactly as given.
///
/// The child is spawned from a dedicated thread with an empty signal mask.
/// Swift's cooperative thread pool blocks SIGTERM on its threads and a child
/// inherits the spawning thread's mask, which would make `terminate()` a no-op.
public struct ProcessCommandRunner: CommandRunner {
    public typealias Result = (exitCode: Int32, stdout: String, stderr: String)

    public static let defaultTimeout: TimeInterval = 600
    /// Seconds after SIGTERM before a still-running child is sent SIGKILL.
    public static let killGracePeriod: TimeInterval = 5

    public let timeout: TimeInterval

    public init() {
        self.init(timeout: Self.defaultTimeout)
    }

    public init(timeout: TimeInterval) {
        self.timeout = max(1, timeout)
    }

    public func run(_ step: CommandStep) async throws -> Result {
        let timeout = self.timeout
        return try await withCheckedThrowingContinuation { continuation in
            let thread = Thread {
                Self.launch(step, timeout: timeout, continuation: continuation)
            }
            thread.name = "ProcessCommandRunner"
            thread.start()
        }
    }

    // MARK: - Implementation

    private static func launch(_ step: CommandStep, timeout: TimeInterval,
                               continuation: CheckedContinuation<Result, any Error>) {
        var noSignals = sigset_t()
        _ = sigemptyset(&noSignals)
        _ = pthread_sigmask(SIG_SETMASK, &noSignals, nil)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: step.executable)
        process.arguments = step.arguments
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let state = RunState()
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .utility)

        group.enter()
        process.terminationHandler = { _ in group.leave() }
        do {
            try process.run()
        } catch {
            group.leave()
            continuation.resume(throwing: CommandRunnerError.launchFailed(executable: step.executable,
                                                                          reason: "\(error)"))
            return
        }

        // Both pipes are drained on background threads so a chatty child never
        // blocks on a full pipe; they return once the child closes its ends.
        group.enter()
        queue.async {
            state.stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        queue.async {
            state.stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        let timeoutSeconds = Int(timeout.rounded(.up))
        let pid = process.processIdentifier
        let forceKill = DispatchWorkItem {
            guard process.isRunning else { return }
            kill(pid, SIGKILL)
        }
        let watchdog = DispatchWorkItem {
            guard process.isRunning else { return }
            state.timedOut = true
            process.terminate()
            queue.asyncAfter(deadline: .now() + killGracePeriod, execute: forceKill)
        }
        queue.asyncAfter(deadline: .now() + timeout, execute: watchdog)

        group.notify(queue: queue) {
            watchdog.cancel()
            forceKill.cancel()
            if state.timedOut {
                continuation.resume(throwing: CommandRunnerError.timedOut(executable: step.executable,
                                                                          seconds: timeoutSeconds))
            } else {
                continuation.resume(returning: (process.terminationStatus, state.stdoutString, state.stderrString))
            }
        }
    }

    /// Output buffers written from the drain threads and the watchdog.
    private final class RunState: @unchecked Sendable {
        private let lock = NSLock()
        private var _stdout = Data()
        private var _stderr = Data()
        private var _timedOut = false

        var stdout: Data {
            get { lock.withLock { _stdout } }
            set { lock.withLock { _stdout = newValue } }
        }
        var stderr: Data {
            get { lock.withLock { _stderr } }
            set { lock.withLock { _stderr = newValue } }
        }
        var timedOut: Bool {
            get { lock.withLock { _timedOut } }
            set { lock.withLock { _timedOut = newValue } }
        }
        var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
        var stderrString: String { String(decoding: stderr, as: UTF8.self) }
    }
}
