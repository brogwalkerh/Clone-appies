import Darwin
import Foundation
import PerformanceModule

/// `LaunchdStateProvider` that asks launchd itself through
/// `/bin/launchctl print <domain>/<label>`.
///
/// Domain mapping follows where launchd actually loads each plist:
/// - `.userAgent` and `.systemAgent` (`~/Library/LaunchAgents`,
///   `/Library/LaunchAgents`) load into the user's GUI domain: `gui/<uid>/<label>`
/// - `.systemDaemon` (`/Library/LaunchDaemons`) loads into `system/<label>`
/// - `.loginItemApp` is not a launchd job: always nil
///
/// Interpretation: exit 0 means the job is loaded (enabled); exit 113 or
/// "Could not find service" means launchd does not know it (disabled or not
/// loaded); anything else (permission denied, launchctl missing) is unknown.
public struct LaunchctlStateProvider: LaunchdStateProvider {
    public static let launchctlURL = URL(fileURLWithPath: "/bin/launchctl")

    private let launchctl: URL

    public init() {
        self.init(launchctl: LaunchctlStateProvider.launchctlURL)
    }

    init(launchctl: URL) {
        self.launchctl = launchctl
    }

    public func isEnabled(label: String, domain: BackgroundItemDomain) async -> Bool? {
        guard let target = LaunchctlStateProvider.serviceTarget(label: label, domain: domain, uid: getuid()) else {
            return nil
        }
        do {
            let output = try await ProcessRunner.run(launchctl,
                                                     arguments: ["print", target],
                                                     capturesStandardError: true)
            return LaunchctlStateProvider.interpret(exitStatus: output.exitStatus,
                                                    output: output.stdoutText + output.stderrText)
        } catch {
            return nil
        }
    }

    // MARK: Pure helpers (tested)

    /// The `<domain>/<label>` argument for `launchctl print`, or nil when the
    /// item is not a launchd job. Labels with path separators or whitespace are
    /// rejected so a hostile plist cannot smuggle extra arguments.
    static func serviceTarget(label: String, domain: BackgroundItemDomain, uid: uid_t) -> String? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) }),
              !trimmed.contains("/")
        else { return nil }
        switch domain {
        case .userAgent, .systemAgent:
            return "gui/\(uid)/\(trimmed)"
        case .systemDaemon:
            return "system/\(trimmed)"
        case .loginItemApp:
            return nil
        }
    }

    static func interpret(exitStatus: Int32, output: String) -> Bool? {
        if exitStatus == 0 { return true }
        if exitStatus == 113 || output.contains("Could not find service") { return false }
        return nil
    }
}
