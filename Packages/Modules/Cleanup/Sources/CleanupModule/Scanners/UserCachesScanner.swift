import Foundation
import CleanerCore

/// One finding per entry of `~/Library/Caches`. Entries owned by another
/// scanner's rule (Xcode, Homebrew, ...) or marked protected are skipped.
///
/// Fails closed: the never-offer set (iCloud sync state, Apple ID caches, ...)
/// lives in the rules table, so when the table is empty (resource bundle
/// missing, JSON failed to decode) or no rule covers an entry, nothing is
/// offered rather than everything as `.safe`.
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
            guard !rules.rules.isEmpty else { return }
            let root = context.homePath("Library/Caches")
            for child in context.readableChildren(of: root) {
                try Task.checkCancellation()
                if context.shouldSkip(child) { continue }
                guard let rule = rules.rule(forPath: child, home: context.home),
                      rule.category == CleanupCategory.userCaches.id else { continue }
                if let finding = await context.finding(at: child, category: CleanupCategory.userCaches,
                                                       scannerID: Self.id, risk: rule.risk,
                                                       detail: rule.description) {
                    emitter.emit(finding)
                }
            }
        }
    }
}
