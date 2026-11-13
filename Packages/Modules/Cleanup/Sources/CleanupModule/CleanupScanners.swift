import Foundation
import CleanerCore

public enum CleanupScanners {
    /// All Cleanup scanners, in display order. Purgeable space is not listed:
    /// it is not a removable item (see `PurgeableSpaceScanner`).
    public static func all() -> [any CleanerScanner] {
        [
            UserCachesScanner(),
            LogsScanner(),
            XcodeScanner(),
            DevToolCachesScanner(),
            AIToolLeftoversScanner(),
            BrokenDownloadsScanner(),
            TrashScanner(),
        ]
    }
}
