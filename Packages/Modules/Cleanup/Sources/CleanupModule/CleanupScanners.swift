import Foundation
import CleanerCore

public enum CleanupScanners {
    /// All Cleanup scanners, in display order.
    public static func all() -> [any CleanerScanner] {
        [
            UserCachesScanner(),
            LogsScanner(),
            XcodeScanner(),
            DevToolCachesScanner(),
            AIToolLeftoversScanner(),
            BrokenDownloadsScanner(),
            TrashScanner(),
            PurgeableSpaceScanner(),
        ]
    }
}
