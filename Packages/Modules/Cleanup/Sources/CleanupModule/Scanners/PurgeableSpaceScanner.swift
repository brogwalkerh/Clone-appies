import Foundation
import CleanerCore

/// One synthetic finding for the boot volume's purgeable space. Yields
/// nothing on platforms other than macOS.
public struct PurgeableSpaceScanner: CleanerScanner {
    public static let id = "cleanup.purgeable"
    public let displayName = "Purgeable Space"
    public let module = ModuleID.cleanup

    private let rules: CleanupRules

    public init(rules: CleanupRules = .shared) {
        self.rules = rules
    }

    public func scan(_ context: ScanContext) -> AsyncThrowingStream<Finding, any Error> {
        let rules = self.rules
        return makeFindingStream { emitter in
            if let finding = Self.purgeableFinding(context: context, rules: rules) {
                emitter.emit(finding)
            }
        }
    }

    /// Purgeable bytes = capacity available for important usage minus the
    /// plain available capacity. nil when not on macOS or nothing is purgeable.
    static func purgeableFinding(context: ScanContext, rules: CleanupRules) -> Finding? {
        #if os(macOS)
        let root = URL(fileURLWithPath: "/", isDirectory: true)
        if context.ignoreList.contains(root) { return nil }
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey,
                                         .volumeAvailableCapacityKey]
        guard let values = try? root.resourceValues(forKeys: keys),
              let important = values.volumeAvailableCapacityForImportantUsage,
              let available = values.volumeAvailableCapacity else { return nil }
        let purgeable = important - Int64(available)
        guard purgeable > 0 else { return nil }
        let rule = rules.rule(id: "purgeable")
        return Finding(path: root, sizeBytes: purgeable, category: CleanupCategory.purgeable,
                       scannerID: id, risk: rule?.risk ?? .safe,
                       detail: rule?.description ?? "Purgeable space macOS can reclaim",
                       modifiedAt: context.now, isDirectory: false)
        #else
        return nil
        #endif
    }
}
