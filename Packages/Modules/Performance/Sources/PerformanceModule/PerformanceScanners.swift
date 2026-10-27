import Foundation
import CleanerCore

public enum PerformanceScanners {
    /// All Performance scanners, in display order.
    public static func all() -> [any CleanerScanner] {
        [
            BrokenLoginItemsScanner(),
        ]
    }
}
