@preconcurrency import Foundation
import HelperProtocol
import os

/// Runs a `HelperCommandPlan` step by step with `Process`. There is no shell
/// anywhere in this file: the executable is an absolute allow-listed path and
/// the arguments are passed as the literal argv the plan authored.
enum CommandExecutor {
    private static let logger = Logger(subsystem: HelperConstants.machServiceName, category: "exec")

    /// Minimal, fixed environment. Nothing from launchd's environment leaks in.
    private static let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]

    struct Outcome {
        let succeeded: Bool
        let message: String
    }

    enum StepError: Error, CustomStringConvertible {
        case executableNotAllowListed(String)
        case launchFailed(String, String)
        case nonZeroExit(String, Int32, String)

        var description: String {
            switch self {
            case .executableNotAllowListed(let exe): return "\(exe) is not an allow-listed executable"
            case .launchFailed(let exe, let reason): return "\(exe) failed to launch: \(reason)"
            case .nonZeroExit(let exe, let code, let stderr):
                let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return "\(exe) exited with status \(code)" + (detail.isEmpty ? "" : ": \(detail)")
            }
        }
    }

    /// Runs every step in order and stops at the first failure.
    static func run(_ plan: HelperCommandPlan) -> Outcome {
        var ran = 0
        var skipped = 0
        for step in plan.steps {
            do {
                if try runStep(step) {
                    ran += 1
                } else {
                    skipped += 1
                }
            } catch let error as StepError {
                return Outcome(succeeded: false, message: error.description)
            } catch {
                return Outcome(succeeded: false, message: error.localizedDescription)
            }
        }
        if plan.steps.isEmpty {
            return Outcome(succeeded: true, message: "OK")
        }
        let summary = skipped == 0 ? "\(ran) step(s) completed" : "\(ran) step(s) completed, \(skipped) skipped"
        return Outcome(succeeded: true, message: summary)
    }

    /// Returns false when the step was skipped because `skipIfMissing` named
    /// a path that does not exist.
    private static func runStep(_ step: CommandStep) throws -> Bool {
        guard step.executable.hasPrefix("/"), HelperCommandPlan.allowedExecutables.contains(step.executable) else {
            throw StepError.executableNotAllowListed(step.executable)
        }
        if let probe = step.skipIfMissing, !FileManager.default.fileExists(atPath: probe) {
            logger.debug("Skipping \(step.executable, privacy: .public): \(probe, privacy: .private) is absent")
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: step.executable)
        process.arguments = step.arguments
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        logger.notice("Running \(step.executable, privacy: .public) \(step.arguments.joined(separator: " "), privacy: .private)")
        do {
            try process.run()
        } catch {
            throw StepError.launchFailed(step.executable, error.localizedDescription)
        }
        // Drain stderr before waiting so a chatty tool cannot block on a full pipe.
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let stderr = String(decoding: stderrData, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw StepError.nonZeroExit(step.executable, process.terminationStatus, stderr)
        }
        return true
    }
}
