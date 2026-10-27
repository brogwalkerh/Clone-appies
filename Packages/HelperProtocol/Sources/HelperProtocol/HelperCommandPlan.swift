import Foundation

/// One process invocation: an absolute executable from the allow-list and its
/// literal argv. Never run through a shell.
public struct CommandStep: Sendable, Hashable, Codable {
    public let executable: String
    public let arguments: [String]
    /// When set, the helper skips this step if no file exists at this path.
    /// Used instead of shell globbing (e.g. Mail's `V8`…`V12` data folders).
    public let skipIfMissing: String?

    public init(executable: String, arguments: [String], skipIfMissing: String? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.skipIfMissing = skipIfMissing
    }
}

/// The fixed argv for each operation. The helper never builds a command line
/// from strings it did not author here; the only caller-supplied values that
/// reach argv are arguments that `HelperRequestValidator` has already accepted.
public struct HelperCommandPlan: Sendable, Hashable, Codable {
    public let steps: [CommandStep]

    public init(steps: [CommandStep]) {
        self.steps = steps
    }

    public enum Executable {
        public static let tmutil = "/usr/bin/tmutil"
        public static let purge = "/usr/sbin/purge"
        public static let dscacheutil = "/usr/bin/dscacheutil"
        public static let killall = "/usr/bin/killall"
        public static let periodic = "/usr/sbin/periodic"
        public static let mdutil = "/usr/bin/mdutil"
        public static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        public static let launchctl = "/bin/launchctl"
        public static let sqlite3 = "/usr/bin/sqlite3"
        public static let rm = "/bin/rm"
    }

    /// Every executable any plan may reference. The helper refuses a step whose
    /// executable is not in this set, even if a future plan mistakenly adds one.
    public static let allowedExecutables: Set<String> = [
        Executable.tmutil, Executable.purge, Executable.dscacheutil, Executable.killall,
        Executable.periodic, Executable.mdutil, Executable.lsregister, Executable.launchctl,
        Executable.sqlite3, Executable.rm,
    ]

    /// Mail data-folder versions whose `Envelope Index` `speedUpMail` vacuums.
    public static let mailDataVersions = 8...12

    /// Builds the plan for an already-validated request.
    public static func plan(for request: HelperRequest) -> HelperCommandPlan {
        plan(for: request.operation, callerHome: request.callerHome)
    }

    /// Builds the plan for `operation`. Precondition: the request carrying
    /// `operation` and `callerHome` passed `HelperRequestValidator.validate`.
    public static func plan(for operation: HelperOperation, callerHome: String) -> HelperCommandPlan {
        switch operation {
        case .ping:
            return HelperCommandPlan(steps: [])

        case .freePurgeableSpace:
            return HelperCommandPlan(steps: [
                CommandStep(executable: Executable.tmutil, arguments: ["thinlocalsnapshots", "/", "9999999999", "4"]),
                CommandStep(executable: Executable.purge, arguments: []),
            ])

        case .flushDNSCache:
            return HelperCommandPlan(steps: [
                CommandStep(executable: Executable.dscacheutil, arguments: ["-flushcache"]),
                CommandStep(executable: Executable.killall, arguments: ["-HUP", "mDNSResponder"]),
            ])

        case .runPeriodicScripts(let interval):
            return HelperCommandPlan(steps: [
                CommandStep(executable: Executable.periodic, arguments: [interval.rawValue]),
            ])

        case .reindexSpotlight(let volume):
            return HelperCommandPlan(steps: [
                CommandStep(executable: Executable.mdutil, arguments: ["-E", volume]),
            ])

        case .rebuildLaunchServices:
            return HelperCommandPlan(steps: [
                CommandStep(executable: Executable.lsregister,
                            arguments: ["-kill", "-r", "-domain", "local", "-domain", "system", "-domain", "user"]),
            ])

        case .thinLocalSnapshots(let bytesToFree):
            return HelperCommandPlan(steps: [
                CommandStep(executable: Executable.tmutil, arguments: ["thinlocalsnapshots", "/", String(bytesToFree), "4"]),
            ])

        case .removeSystemCache(let path):
            return HelperCommandPlan(steps: [
                CommandStep(executable: Executable.rm, arguments: ["-rf", "--", path]),
            ])

        case .setLaunchDaemonEnabled(let label, let enabled):
            return HelperCommandPlan(steps: [
                CommandStep(executable: Executable.launchctl, arguments: [enabled ? "enable" : "disable", "system/" + label]),
            ])

        case .resetBluetoothModule:
            return HelperCommandPlan(steps: [
                CommandStep(executable: Executable.killall, arguments: ["bluetoothd"]),
            ])

        case .speedUpMail:
            let steps = mailDataVersions.map { version -> CommandStep in
                let index = callerHome + "/Library/Mail/V\(version)/MailData/Envelope Index"
                return CommandStep(executable: Executable.sqlite3, arguments: [index, "VACUUM;"], skipIfMissing: index)
            }
            return HelperCommandPlan(steps: steps)
        }
    }
}
