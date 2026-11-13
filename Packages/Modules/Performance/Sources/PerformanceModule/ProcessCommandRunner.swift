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

        process.terminationHandler = { _ in state.reaped = true }
        do {
            try process.run()
        } catch {
            continuation.resume(throwing: CommandRunnerError.launchFailed(executable: step.executable,
                                                                          reason: "\(error)"))
            return
        }

        // Both pipes are drained on background threads so a chatty child never
        // blocks on a full pipe. A drain ends at end-of-file or, once the
        // child itself has exited, as soon as the pipe is empty: a descendant
        // that inherited the pipe and outlives the child (or survives the
        // timeout kill) must not keep the run, and the serial maintenance
        // queue behind it, waiting forever. The run completes when both
        // drains have; it does not wait for `terminationHandler`, which
        // swift-corelibs-foundation also delays until such a descendant exits.
        let pid = process.processIdentifier
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        group.enter()
        queue.async {
            drain(stdoutHandle.fileDescriptor, child: pid, state: state) { state.appendStdout($0) }
            group.leave()
        }
        group.enter()
        queue.async {
            drain(stderrHandle.fileDescriptor, child: pid, state: state) { state.appendStderr($0) }
            group.leave()
        }

        let timeoutSeconds = Int(timeout.rounded(.up))
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
            // End-of-file on both pipes can precede the exit (the child closed
            // them, or simply has not been reaped yet); the watchdog still
            // bounds this wait.
            var pause: UInt32 = 1_000
            while !hasExited(pid, state: state) {
                usleep(pause)
                pause = min(pause * 2, 100_000)
            }
            watchdog.cancel()
            forceKill.cancel()
            // Both drains have returned, so nothing is reading these any more.
            try? stdoutHandle.close()
            try? stderrHandle.close()
            if state.timedOut {
                continuation.resume(throwing: CommandRunnerError.timedOut(executable: step.executable,
                                                                          seconds: timeoutSeconds))
            } else {
                let status = state.reaped ? process.terminationStatus : (state.observedStatus ?? -1)
                continuation.resume(returning: (status, state.stdoutString, state.stderrString))
            }
        }
    }

    /// How long a drain waits for output before re-checking whether the child exited.
    private static let drainPollMilliseconds: Int32 = 100

    /// Reads `descriptor` until end-of-file. After the child has exited, stops
    /// at the first moment the pipe has nothing buffered, even if another
    /// process still holds the write end open.
    private static func drain(_ descriptor: Int32, child: pid_t, state: RunState, append: (Data) -> Void) {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            // Checked before polling: output written before the exit is already
            // in the pipe, so an empty poll after this point means "done".
            let exited = hasExited(child, state: state)
            var descriptorState = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptorState, 1, drainPollMilliseconds)
            if ready < 0 {
                if errno == EINTR { continue }
                return
            }
            if ready == 0 {
                if exited { return }
                continue
            }
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return
            }
            if count == 0 { return }
            append(Data(buffer[0..<count]))
        }
    }

    /// True once Foundation has reaped the child, or a non-reaping `waitid`
    /// shows it has terminated (its status is then kept in `state`, leaving
    /// the zombie for Foundation to collect).
    private static func hasExited(_ child: pid_t, state: RunState) -> Bool {
        if state.reaped || state.observedStatus != nil { return true }
        var info = siginfo_t()
        guard waitid(P_PID, id_t(child), &info, WEXITED | WNOHANG | WNOWAIT) == 0,
              info.si_signo == SIGCHLD else { return false }
        #if os(Linux)
        state.observedStatus = info._sifields._sigchld.si_status
        #else
        state.observedStatus = info.si_status
        #endif
        return true
    }

    /// Output buffers and flags shared by the drain threads, the watchdog and the termination handler.
    private final class RunState: @unchecked Sendable {
        private let lock = NSLock()
        private var _stdout = Data()
        private var _stderr = Data()
        private var _timedOut = false
        private var _reaped = false
        private var _observedStatus: Int32?

        var stdout: Data { lock.withLock { _stdout } }
        var stderr: Data { lock.withLock { _stderr } }
        func appendStdout(_ data: Data) { lock.withLock { _stdout.append(data) } }
        func appendStderr(_ data: Data) { lock.withLock { _stderr.append(data) } }
        /// Set by the termination handler: `terminationStatus` is readable.
        var reaped: Bool {
            get { lock.withLock { _reaped } }
            set { lock.withLock { _reaped = newValue } }
        }
        /// Exit code or terminating signal seen by `waitid` before Foundation reaped the child.
        var observedStatus: Int32? {
            get { lock.withLock { _observedStatus } }
            set { lock.withLock { _observedStatus = newValue } }
        }
        var timedOut: Bool {
            get { lock.withLock { _timedOut } }
            set { lock.withLock { _timedOut = newValue } }
        }
        var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
        var stderrString: String { String(decoding: stderr, as: UTF8.self) }
    }
}
