import Foundation
import CleanerCore

/// Model and cache directories left behind by local AI tooling (Ollama,
/// LM Studio, Hugging Face, PyTorch, pip, Xcode predictive completion).
public struct AIToolLeftoversScanner: CleanerScanner {
    public static let id = "cleanup.aiLeftovers"
    public let displayName = "AI Tool Leftovers"
    public let module = ModuleID.cleanup

    private let rules: CleanupRules

    public init(rules: CleanupRules = .shared) {
        self.rules = rules
    }

    public func scan(_ context: ScanContext) -> AsyncThrowingStream<Finding, any Error> {
        let rules = self.rules
        return makeFindingStream { emitter in
            try await context.emitRulePaths(ruleCategory: CleanupCategory.aiLeftovers.id,
                                            category: CleanupCategory.aiLeftovers,
                                            scannerID: Self.id, rules: rules, emitter: emitter)
        }
    }
}
