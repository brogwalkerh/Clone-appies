import Foundation
import CleanerCore

/// One finding per entry of `~/Library/Caches`. Entries owned by another
/// scanner's rule (Xcode, Homebrew, ...) or marked protected are skipped.
public struct UserCachesScanner: CleanerScanner {
    public static let id = "cleanup.userCaches"
    public let displayName = "User Cache Files"
    public let module = ModuleID.cleanup

    private let rules: CleanupRules

    public init(rules: CleanupRules = .shared) {
        self.rules = rules
    }

    public func scan(_ context: ScanContext) -> AsyncThrowingStream<Finding, any Error> {
        let rules = self.rules
        return makeFindingStream { emitter in
            let root = context.homePath("Library/Caches")
            for child in context.readableChildren(of: root) {
                try Task.checkCancellation()
                if context.shouldSkip(child) { continue }
                let rule = rules.rule(forPath: child, home: context.home)
                if let rule, rule.category != CleanupCategory.userCaches.id { continue }
                if let finding = await context.finding(at: child, category: CleanupCategory.userCaches,
                                                       scannerID: Self.id, risk: rule?.risk ?? .safe,
                                                       detail: rule?.description) {
                    emitter.emit(finding)
                }
            }
        }
    }
}
