import Foundation
import CleanerCore
import SmartCareModule
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Smart Insights (PLAN.md §3.2): Apple Intelligence's on-device model
/// explains a finding when it is available; the Cleanup rule table answers
/// otherwise, so the feature works offline and on Macs without it.
enum InsightService {
    static let provider: any InsightProvider = FallbackInsightProvider(
        primary: OnDeviceInsightProvider(),
        fallback: RuleTableInsightProvider())
}

/// Asks the on-device language model (Foundation Models framework). Only facts
/// we know go into the prompt (`InsightPrompt`), and the safety advice comes
/// from our own risk rating, never from the model.
struct OnDeviceInsightProvider: InsightProvider {
    private let rules = RuleTableInsightProvider()

    func insight(for finding: Finding, home: URL) async -> Insight? {
        #if canImport(FoundationModels)
        guard SystemLanguageModel.default.isAvailable else { return nil }
        let prompt = InsightPrompt.make(for: finding, home: home, ruleText: rules.ruleText(for: finding, home: home))
        do {
            let session = LanguageModelSession(instructions: InsightPrompt.instructions)
            let response = try await session.respond(to: prompt)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return Insight(title: finding.category.displayName,
                           explanation: text,
                           advice: RuleTableInsightProvider.advice(for: finding),
                           source: .onDeviceModel)
        } catch {
            // Guardrail refusals, context limits, model not ready: fall back to the rules.
            return nil
        }
        #else
        return nil
        #endif
    }
}
