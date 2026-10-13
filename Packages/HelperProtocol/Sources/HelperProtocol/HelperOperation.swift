import Foundation

/// The closed set of operations the privileged helper performs (ADR 0002,
/// CLAUDE.md rule 5). Every case is a typed request; there is deliberately no
/// case that carries a shell command, a script body, a format string, an
/// executable path or an unconstrained "delete this path" argument. Adding a
/// root capability means adding a case here, a validation rule in
/// `HelperRequestValidator`, a fixed argv in `HelperCommandPlan` and tests.
public enum HelperOperation: Codable, Sendable, Hashable {
    /// Protocol liveness check; the helper runs nothing.
    case ping
    /// `tmutil thinlocalsnapshots / 9999999999 4` followed by `purge`.
    case freePurgeableSpace
    /// `dscacheutil -flushcache` then `killall -HUP mDNSResponder`.
    case flushDNSCache
    /// `periodic daily|weekly|monthly`.
    case runPeriodicScripts(PeriodicInterval)
    /// `mdutil -E <volume>`; `volume` must be "/" or "/Volumes/<name>".
    case reindexSpotlight(volume: String)
    /// `lsregister -kill -r -domain local -domain system -domain user`.
    case rebuildLaunchServices
    /// `tmutil thinlocalsnapshots / <bytesToFree> 4`; `bytesToFree` must be > 0.
    case thinLocalSnapshots(bytesToFree: Int64)
    /// `rm -rf -- <path>`; `path` must be a standardized absolute path strictly
    /// under `/Library/Caches/` or `/private/var/folders/`, contain no "..",
    /// and must not itself be a symbolic link.
    case removeSystemCache(path: String)
    /// `launchctl enable|disable system/<label>`; `label` must match
    /// `^[A-Za-z0-9_.-]+$` and must not start with `com.apple.`.
    case setLaunchDaemonEnabled(label: String, enabled: Bool)
    /// `killall bluetoothd` (launchd restarts it).
    case resetBluetoothModule
    /// `sqlite3 "<callerHome>/Library/Mail/V<n>/MailData/Envelope Index" "VACUUM;"`
    /// for each supported Mail data version; steps whose index file does not
    /// exist are skipped (see `CommandStep.skipIfMissing`).
    case speedUpMail

    /// Stable, human-readable name used in logs and manifests.
    public var name: String {
        switch self {
        case .ping: return "ping"
        case .freePurgeableSpace: return "freePurgeableSpace"
        case .flushDNSCache: return "flushDNSCache"
        case .runPeriodicScripts: return "runPeriodicScripts"
        case .reindexSpotlight: return "reindexSpotlight"
        case .rebuildLaunchServices: return "rebuildLaunchServices"
        case .thinLocalSnapshots: return "thinLocalSnapshots"
        case .removeSystemCache: return "removeSystemCache"
        case .setLaunchDaemonEnabled: return "setLaunchDaemonEnabled"
        case .resetBluetoothModule: return "resetBluetoothModule"
        case .speedUpMail: return "speedUpMail"
        }
    }

    /// Operations whose effect is measured as reclaimed disk space.
    public var reportsBytesReclaimed: Bool {
        switch self {
        case .freePurgeableSpace, .thinLocalSnapshots, .removeSystemCache: return true
        default: return false
        }
    }
}

/// Argument of `HelperOperation.runPeriodicScripts`.
public enum PeriodicInterval: String, Codable, Sendable, CaseIterable {
    case daily
    case weekly
    case monthly
}
