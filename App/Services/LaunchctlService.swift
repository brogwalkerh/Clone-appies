import Foundation

/// Enables and disables the current user's launch agents with `launchctl`
/// (`bootout` / `bootstrap gui/<uid> <plist>`). User-domain only: system
/// agents and daemons go through the privileged helper's
/// `setLaunchDaemonEnabled` operation, never through here.
struct LaunchctlService: Sendable {
    enum Failure: LocalizedError, Sendable {
        case notAUserAgentPlist(String)
        case commandFailed(subcommand: String, exitCode: Int32, stderr: String)

        var errorDescription: String? {
            switch self {
            case .notAUserAgentPlist(let path):
                return "\(path) is not a launch agent plist in your Library folder."
            case .commandFailed(let subcommand, let exitCode, let stderr):
                let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return "launchctl \(subcommand) failed (\(exitCode))\(detail.isEmpty ? "." : ": \(detail)")"
            }
        }
    }

    private static let launchctl = URL(fileURLWithPath: "/bin/launchctl")

    init() {}

    /// Loads (`enabled == true`) or unloads the agent described by `plistURL`
    /// into the GUI domain of the current user. Throws when the plist is not
    /// under `~/Library/LaunchAgents` so this can never touch system domains.
    func setUserAgentEnabled(plistURL: URL, enabled: Bool) async throws {
        let standardized = plistURL.standardizedFileURL
        let path = standardized.path(percentEncoded: false)
        let agentsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .standardizedFileURL
            .path(percentEncoded: false)
        guard path.hasPrefix(agentsDir.hasSuffix("/") ? agentsDir : agentsDir + "/"),
              standardized.pathExtension == "plist",
              !path.contains("/../") else {
            throw Failure.notAUserAgentPlist(path)
        }
        let domain = "gui/\(getuid())"
        let subcommand = enabled ? "bootstrap" : "bootout"
        try await run(arguments: [subcommand, domain, path], subcommand: subcommand)
    }

    private func run(arguments: [String], subcommand: String) async throws {
        let outcome = try await Task.detached(priority: .userInitiated) { () throws -> (Int32, String) in
            let process = Process()
            process.executableURL = LaunchctlService.launchctl
            process.arguments = arguments
            let stderrPipe = Pipe()
            process.standardError = stderrPipe
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
        // `bootout` of an agent that is not loaded exits 3/113 ("No such process");
        // treat that as already disabled rather than an error.
        // TODO(macOS27): confirm these launchctl exit codes on the 27 SDK's launchctl.
        if outcome.0 != 0, !(subcommand == "bootout" && (outcome.0 == 3 || outcome.0 == 113)) {
            throw Failure.commandFailed(subcommand: subcommand, exitCode: outcome.0, stderr: outcome.1)
        }
    }
}
