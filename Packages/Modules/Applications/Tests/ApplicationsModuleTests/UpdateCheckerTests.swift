import Foundation
import Testing
import CleanerCore
import CleanerCoreTesting
@testable import ApplicationsModule

/// Answers a fixed table of updates, optionally after a delay.
struct FakeUpdateSource: UpdateSource {
    let updates: [AvailableUpdate]
    var delay: Duration = .zero

    func check(_ apps: [InstalledApp]) async -> [AvailableUpdate] {
        if delay > .zero { try? await Task.sleep(for: delay) }
        let wanted = Set(apps.map(\.bundleURL))
        return updates.filter { wanted.contains($0.app.bundleURL) }
    }
}

@Suite("UpdateChecker")
struct UpdateCheckerTests {
    let alpha = makeApp(name: "Alpha", id: "com.vendor.alpha", version: "1.0", build: "10")
    let beta = makeApp(name: "Beta", id: "com.vendor.beta", version: "2.0", build: "20")
    let gamma = makeApp(name: "Gamma", id: "com.vendor.gamma", version: "3.0", build: "30")

    func update(_ app: InstalledApp, _ version: String, _ source: AppSource) -> AvailableUpdate {
        AvailableUpdate(app: app, latestVersion: version, downloadURL: URL(string: "https://e/\(source.rawValue)"),
                        releaseNotesURL: nil, source: source)
    }

    @Test func mergesByAppPreferringHighestVersion() async {
        let sparkle = FakeUpdateSource(updates: [update(alpha, "1.5", .direct), update(beta, "2.1", .direct)], delay: .milliseconds(20))
        let brew = FakeUpdateSource(updates: [update(alpha, "1.10", .homebrewCask), update(gamma, "3.1", .homebrewCask)])
        let store = FakeUpdateSource(updates: [update(beta, "2.1", .appStore)])
        let checker = UpdateChecker(sources: [sparkle, brew, store])
        let merged = await checker.check([alpha, beta, gamma])
        #expect(merged.map(\.app.name) == ["Alpha", "Beta", "Gamma"])
        #expect(merged.map(\.latestVersion) == ["1.10", "2.1", "3.1"])
        #expect(merged[0].source == .homebrewCask)
        #expect(merged[1].source == .direct, "ties go to the earlier-listed source")
    }

    @Test func onlyRequestedAppsAreReported() async {
        let source = FakeUpdateSource(updates: [update(alpha, "1.5", .direct), update(beta, "2.1", .direct)])
        let checker = UpdateChecker(sources: [source])
        let merged = await checker.check([beta])
        #expect(merged.map(\.app.name) == ["Beta"])
    }

    @Test func emptyInputs() async {
        #expect(await UpdateChecker(sources: []).check([alpha]).isEmpty)
        #expect(await UpdateChecker(sources: [FakeUpdateSource(updates: [update(alpha, "9", .direct)])]).check([]).isEmpty)
    }

    @Test func boundedFanOutStillRunsEverySource() async {
        let sources: [any UpdateSource] = (0..<7).map { index in
            FakeUpdateSource(updates: [update(alpha, "1.\(index)", .direct)], delay: .milliseconds(5))
        }
        let checker = UpdateChecker(sources: sources, maxConcurrency: 2)
        let merged = await checker.check([alpha])
        #expect(merged.count == 1)
        #expect(merged.first?.latestVersion == "1.6")
    }

    @Test func availableUpdateIsCodable() throws {
        let value = update(alpha, "1.5", .direct)
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(AvailableUpdate.self, from: data) == value)
    }
}
