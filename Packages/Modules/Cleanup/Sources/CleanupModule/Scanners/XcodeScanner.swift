import Foundation
import CleanerCore

/// Xcode build products, archives, device symbols and caches.
public struct XcodeScanner: CleanerScanner {
    public static let id = "cleanup.xcode"
    public let displayName = "Xcode Junk"
    public let module = ModuleID.cleanup

    private let rules: CleanupRules

    public init(rules: CleanupRules = .shared) {
        self.rules = rules
    }

    /// Rules whose paths are parents: each child is one finding.
    private static let perChildRuleIDs = ["xcode.derivedData", "xcode.archives", "xcode.deviceSupport"]
    /// Rules whose paths are reported as a single finding.
    private static let wholeRuleIDs = ["xcode.simulatorCaches", "xcode.caches"]

    public func scan(_ context: ScanContext) -> AsyncThrowingStream<Finding, any Error> {
        let rules = self.rules
        return makeFindingStream { emitter in
            for ruleID in Self.perChildRuleIDs {
                guard let rule = rules.rule(id: ruleID) else { continue }
                for relative in rule.relativePaths {
                    let parent = context.homePath(relative)
                    for child in context.readableChildren(of: parent) {
                        try Task.checkCancellation()
                        if let finding = await context.finding(at: child, category: CleanupCategory.xcode,
                                                               scannerID: Self.id, risk: rule.risk,
                                                               detail: rule.description) {
                            emitter.emit(finding)
                        }
                    }
                }
            }
            for ruleID in Self.wholeRuleIDs {
                guard let rule = rules.rule(id: ruleID) else { continue }
                for relative in rule.relativePaths {
                    try Task.checkCancellation()
                    let url = context.homePath(relative)
                    guard context.fileSystem.exists(url) else { continue }
                    if let finding = await context.finding(at: url, category: CleanupCategory.xcode,
                                                           scannerID: Self.id, risk: rule.risk,
                                                           detail: rule.description) {
                        emitter.emit(finding)
                    }
                }
            }
        }
    }
}
