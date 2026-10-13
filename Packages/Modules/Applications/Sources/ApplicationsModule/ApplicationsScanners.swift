import Foundation
import CleanerCore

public enum ApplicationsScanners {
    /// All Applications scanners, in display order.
    public static func all() -> [any CleanerScanner] {
        [
            OrphanedLeftoversScanner(),
            InstallersScanner(),
        ]
    }
}
