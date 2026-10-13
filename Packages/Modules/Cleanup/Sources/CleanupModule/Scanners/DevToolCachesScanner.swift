import Foundation
import CleanerCore

/// Package-manager and build-tool caches (Homebrew, npm, yarn, Gradle, Maven,
/// Cargo, CocoaPods, SwiftPM, pip) and the Docker Desktop virtual disk.
public struct DevToolCachesScanner: CleanerScanner {
    public static let id = "cleanup.devCaches"
    public let displayName = "Developer Tool Caches"
    public let module = ModuleID.cleanup

    private let rules: CleanupRules

    public init(rules: CleanupRules = .shared) {
        self.rules = rules
    }

    public func scan(_ context: ScanContext) -> AsyncThrowingStream<Finding, any Error> {
        let rules = self.rules
        return makeFindingStream { emitter in
            try await context.emitRulePaths(ruleCategory: CleanupCategory.devCaches.id,
                                            category: CleanupCategory.devCaches,
                                            scannerID: Self.id, rules: rules, emitter: emitter)
        }
    }
}
