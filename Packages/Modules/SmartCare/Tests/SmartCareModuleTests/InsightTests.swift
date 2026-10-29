import Foundation
import Testing
import CleanerCore
import CleanupModule
@testable import SmartCareModule

private let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)

private struct Silent: InsightProvider {
    func insight(for finding: Finding, home: URL) async -> Insight? { nil }
}

private struct Canned: InsightProvider {
    func insight(for finding: Finding, home: URL) async -> Insight? {
        Insight(title: "Model", explanation: "From the model.", advice: "Ok.", source: .onDeviceModel)
    }
}

@Suite("Insights")
struct InsightTests {
    @Test func cleanupRuleTextWinsForAMatchingPath() async throws {
        let rules = CleanupRules(rules: [CleanupRule(id: "spotify", category: "cleanup.userCaches",
                                                     relativePaths: ["Library/Caches/com.spotify.client"],
                                                     risk: .caution, description: "Spotify's offline song cache.")])
        let provider = RuleTableInsightProvider(rules: rules)
        let item = finding("/Users/test/Library/Caches/com.spotify.client", 1_000, risk: .caution)
        let insight = try #require(await provider.insight(for: item, home: home))
        #expect(insight.explanation == "Spotify's offline song cache.")
        #expect(insight.advice.hasPrefix("Usually safe"))
        #expect(insight.source == .rules)
        #expect(insight.title == "User Cache Files")
    }

    @Test func fallsBackToTheCategoryTable() async throws {
        let provider = RuleTableInsightProvider(rules: CleanupRules(rules: []))
        let movie = try #require(await provider.insight(for: finding("/Users/test/Movies/a.mov", 9, clutterCategory), home: home))
        #expect(movie.explanation.contains("large file"))
        #expect(movie.advice.contains("your own files"))
        let privacy = FindingCategory(id: "privacy.safariHistory", displayName: "Safari History", module: .protection)
        let history = try #require(await provider.insight(for: finding("/Users/test/Library/Safari/History.db", 1, privacy), home: home))
        #expect(history.explanation.contains("Browsing"))
        let unknown = FindingCategory(id: "other.thing", displayName: "Thing", module: .cleanup)
        #expect(await provider.insight(for: finding("/x", 1, unknown), home: home) == nil)
    }

    @Test func everyBuiltInCategoryHasText() {
        let ids = ["cleanup.userCaches", "cleanup.logs", "cleanup.trash", "clutter.duplicates",
                   "applications.orphaned", "performance.brokenLoginItems", "protection.malware"]
        for id in ids { #expect(RuleTableInsightProvider.categoryTable[id] != nil, "\(id)") }
    }

    @Test func fallbackProviderPrefersPrimary() async {
        let item = finding("/x", 1)
        #expect(await FallbackInsightProvider(primary: Canned(), fallback: RuleTableInsightProvider()).insight(for: item, home: home)?.source == .onDeviceModel)
        #expect(await FallbackInsightProvider(primary: Silent(), fallback: RuleTableInsightProvider()).insight(for: item, home: home)?.source == .rules)
    }

    @Test func promptCarriesFactsOnly() {
        let item = Finding(path: URL(fileURLWithPath: "/Users/test/Library/Caches/x"), sizeBytes: 2_500_000_000,
                           category: cleanupCategory, scannerID: "s", risk: .safe, detail: "From app X",
                           modifiedAt: date("2026-09-01T10:00:00Z"), isDirectory: true)
        let prompt = InsightPrompt.make(for: item, home: home, ruleText: "App caches.")
        #expect(prompt.contains("Item: ~/Library/Caches/x"))
        #expect(prompt.contains("Kind: folder"))
        #expect(prompt.contains("Size: \(ByteFormatter.string(2_500_000_000))"))
        #expect(prompt.contains("Last modified: 2026-09-01"))
        #expect(prompt.contains("Known description: App caches."))
        #expect(prompt.contains("Scanner note: From app X"))
        #expect(!prompt.contains("/Users/test"))
        #expect(InsightPrompt.displayPath(URL(fileURLWithPath: "/Applications/A.app"), home: home) == "/Applications/A.app")
        #expect(InsightPrompt.displayPath(URL(fileURLWithPath: "/Users/testing/x"), home: home) == "/Users/testing/x")
    }
}
