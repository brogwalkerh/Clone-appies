import Foundation
import CleanerCore

/// Purgeable space on the boot volume. This is a *measurement*, never a
/// finding: purgeable space is not a file, so it must not flow into a
/// `Remover` (its only honest path would be "/", an ancestor of every
/// protected path and of every other finding). Reclaiming it is the
/// "Free Up Purgeable Space" maintenance task.
///
/// The type keeps its `CleanerScanner` conformance for source compatibility
/// but is not registered in `CleanupScanners.all()` and `scan` never yields.
public struct PurgeableSpaceScanner: CleanerScanner {
    public static let id = "cleanup.purgeable"
    public let displayName = "Purgeable Space"
    public let module = ModuleID.cleanup

    public init(rules: CleanupRules = .shared) {}

    /// Always empty; see the type comment. Use `purgeableBytes()` to display
    /// the figure.
    public func scan(_ context: ScanContext) -> AsyncThrowingStream<Finding, any Error> {
        makeFindingStream { _ in }
    }

    /// Purgeable bytes = capacity available for important usage minus the
    /// plain available capacity. nil when not on macOS, when the volume
    /// cannot be queried, or when nothing is purgeable.
    public static func purgeableBytes() -> Int64? {
        #if os(macOS)
        let root = URL(fileURLWithPath: "/", isDirectory: true)
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey,
                                         .volumeAvailableCapacityKey]
        guard let values = try? root.resourceValues(forKeys: keys),
              let important = values.volumeAvailableCapacityForImportantUsage,
              let available = values.volumeAvailableCapacity else { return nil }
        let purgeable = important - Int64(available)
        return purgeable > 0 ? purgeable : nil
        #else
        return nil
        #endif
    }
}
