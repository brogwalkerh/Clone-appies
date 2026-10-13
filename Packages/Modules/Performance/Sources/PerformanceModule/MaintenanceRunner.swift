import Foundation
import CleanerCore
import HelperProtocol

public struct MaintenanceResult: Sendable, Hashable, Codable {
    public let taskID: String
    public let succeeded: Bool
    public let message: String
    public let bytesReclaimed: Int64?
    public let duration: TimeInterval

    public init(taskID: String, succeeded: Bool, message: String,
                bytesReclaimed: Int64? = nil, duration: TimeInterval) {
        self.taskID = taskID
        self.succeeded = succeeded
        self.message = message
        self.bytesReclaimed = bytesReclaimed
        self.duration = duration
    }
}

/// Runs one user-level command step and reports its exit status and output.
public protocol CommandRunner: Sendable {
    func run(_ step: CommandStep) async throws -> (exitCode: Int32, stdout: String, stderr: String)
}

/// Performs one privileged operation through the helper (XPC on macOS).
public protocol HelperPerformer: Sendable {
    func perform(_ operation: HelperOperation) async throws -> HelperResponse
}

/// Executes maintenance tasks one at a time.
///
/// Tasks never run concurrently, even when `run` is called from several
/// tasks at once: each call waits for the previous one to finish. User-level
/// tasks run via the injected `CommandRunner`; helper tasks via the injected
/// `HelperPerformer`, and fail immediately when no helper is installed.
public actor MaintenanceRunner {
    public static let helperMissingMessage = "Privileged helper not installed"

    private let commands: any CommandRunner
    private let helper: (any HelperPerformer)?
    private let home: URL
    private var tail: Task<Void, Never>?

    public init(commands: any CommandRunner, helper: (any HelperPerformer)?, home: URL) {
        self.commands = commands
        self.helper = helper
        self.home = home.standardizedFileURL
    }

    public func run(_ task: MaintenanceTask) async -> MaintenanceResult {
        let previous = tail
        let commands = self.commands
        let helper = self.helper
        let home = self.home
        let work = Task<MaintenanceResult, Never> {
            await previous?.value
            return await Self.execute(task, commands: commands, helper: helper, home: home)
        }
        tail = Task { _ = await work.value }
        return await work.value
    }

    /// Runs `tasks` in order, yielding each result as it completes.
    public func run(_ tasks: [MaintenanceTask]) -> AsyncStream<MaintenanceResult> {
        let (stream, continuation) = AsyncStream<MaintenanceResult>.makeStream(bufferingPolicy: .unbounded)
        let job = Task {
            for task in tasks {
                if Task.isCancelled { break }
                continuation.yield(await self.run(task))
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in job.cancel() }
        return stream
    }

    // MARK: - Execution

    private static func execute(_ task: MaintenanceTask, commands: any CommandRunner,
                                helper: (any HelperPerformer)?, home: URL) async -> MaintenanceResult {
        let clock = ContinuousClock()
        let start = clock.now
        let outcome: Outcome
        if task.requiresHelper {
            outcome = await executeHelper(task, helper: helper)
        } else {
            outcome = await executeUser(task, commands: commands, home: home)
        }
        let elapsed = clock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return MaintenanceResult(taskID: task.id, succeeded: outcome.succeeded, message: outcome.message,
                                 bytesReclaimed: outcome.bytesReclaimed, duration: seconds)
    }

    private struct Outcome {
        var succeeded: Bool
        var message: String
        var bytesReclaimed: Int64?
    }

    private static func executeHelper(_ task: MaintenanceTask, helper: (any HelperPerformer)?) async -> Outcome {
        guard let helper else {
            return Outcome(succeeded: false, message: helperMissingMessage)
        }
        let operations = task.helperOperations
        guard !operations.isEmpty else {
            return Outcome(succeeded: false, message: "Task \(task.id) declares no helper operation")
        }
        var bytes: Int64?
        var messages: [String] = []
        for operation in operations {
            let response: HelperResponse
            do {
                response = try await helper.perform(operation)
            } catch {
                return Outcome(succeeded: false, message: "Helper request failed: \(error)", bytesReclaimed: bytes)
            }
            if let reclaimed = response.bytesReclaimed {
                bytes = (bytes ?? 0) + reclaimed
            }
            let message = response.message.trimmingCharacters(in: .whitespacesAndNewlines)
            if !response.succeeded {
                return Outcome(succeeded: false,
                               message: message.isEmpty ? "Helper operation failed" : message,
                               bytesReclaimed: bytes)
            }
            if !message.isEmpty { messages.append(message) }
        }
        let message = messages.isEmpty ? "Completed" : messages.joined(separator: "; ")
        return Outcome(succeeded: true, message: message, bytesReclaimed: bytes)
    }

    private static func executeUser(_ task: MaintenanceTask, commands: any CommandRunner, home: URL) async -> Outcome {
        guard !task.userSteps.isEmpty else {
            return Outcome(succeeded: false, message: "Task \(task.id) declares no commands to run")
        }
        for step in task.userSteps {
            let resolved = expandingHome(step, home: home)
            let result: (exitCode: Int32, stdout: String, stderr: String)
            do {
                result = try await commands.run(resolved)
            } catch {
                return Outcome(succeeded: false, message: "Could not run \(resolved.executable): \(error)")
            }
            if result.exitCode != 0 {
                let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                var message = "\(resolved.executable) exited with status \(result.exitCode)"
                if !stderr.isEmpty { message += ": \(stderr)" }
                return Outcome(succeeded: false, message: message)
            }
        }
        let count = task.userSteps.count
        return Outcome(succeeded: true, message: "Completed \(count) \(count == 1 ? "command" : "commands")")
    }

    /// Expands a leading `~` in the executable and arguments against `home`.
    static func expandingHome(_ step: CommandStep, home: URL) -> CommandStep {
        func expand(_ value: String) -> String {
            guard value == "~" || value.hasPrefix("~/") else { return value }
            return home.path + value.dropFirst()
        }
        return CommandStep(executable: expand(step.executable), arguments: step.arguments.map(expand))
    }
}
