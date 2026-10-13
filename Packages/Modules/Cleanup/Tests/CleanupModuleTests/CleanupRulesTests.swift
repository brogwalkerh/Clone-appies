import Foundation
import Testing
import CleanerCore
import CleanerCoreTesting
@testable import CleanupModule

@Suite("CleanupRules")
struct CleanupRulesTests {
    let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)

    @Test func bundledRulesLoad() {
        let rules = CleanupRules.shared
        #expect(rules.rules.count >= 30)
    }

    @Test func ruleIDsAreUnique() {
        let ids = CleanupRules.shared.rules.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func everyRelativePathIsNonEmpty() {
        for rule in CleanupRules.shared.rules {
            #expect(!rule.relativePaths.isEmpty, "rule \(rule.id) has no paths")
            for path in rule.relativePaths {
                #expect(!path.trimmingCharacters(in: .whitespaces).isEmpty, "rule \(rule.id) has an empty path")
            }
            #expect(!rule.description.isEmpty, "rule \(rule.id) has no description")
            #expect(rule.category.hasPrefix("cleanup."), "rule \(rule.id) category \(rule.category)")
        }
    }

    @Test func everyCategoryIsKnown() {
        let known: Set<String> = [
            "cleanup.userCaches", "cleanup.logs", "cleanup.crashReports", "cleanup.xcode",
            "cleanup.trash", "cleanup.brokenDownloads", "cleanup.oldInstallers", "cleanup.aiLeftovers",
            "cleanup.devCaches", "cleanup.purgeable", CleanupRules.protectedCategory,
        ]
        for rule in CleanupRules.shared.rules {
            #expect(known.contains(rule.category), "unknown category \(rule.category) in \(rule.id)")
        }
    }

    @Test func lookupByID() {
        let rule = CleanupRules.shared.rule(id: "xcode.archives")
        #expect(rule?.risk == .risky)
        #expect(rule?.description.hasPrefix("Contains dSYMs for shipped builds") == true)
        #expect(CleanupRules.shared.rule(id: "nope") == nil)
    }

    @Test func mostSpecificRuleWins() {
        let rules = CleanupRules.shared
        let safari = home.appendingPathComponent("Library/Caches/com.apple.Safari/WebKit")
        #expect(rules.rule(forPath: safari, home: home)?.id == "userCaches.safari")
        let unknown = home.appendingPathComponent("Library/Caches/com.example.app")
        #expect(rules.rule(forPath: unknown, home: home)?.id == "userCaches")
        let xcode = home.appendingPathComponent("Library/Caches/com.apple.dt.Xcode")
        #expect(rules.rule(forPath: xcode, home: home)?.category == "cleanup.xcode")
        let predictive = xcode.appendingPathComponent("PredictiveCodeCompletion/model.bin")
        #expect(rules.rule(forPath: predictive, home: home)?.id == "xcode.caches")
    }

    @Test func descriptionFallback() {
        let rules = CleanupRules.shared
        let ollama = home.appendingPathComponent(".ollama/models/blobs/sha256-abc")
        #expect(rules.description(forPath: ollama, home: home)?.contains("Ollama") == true)
        #expect(rules.description(forPath: home.appendingPathComponent("Documents/thesis.pdf"), home: home) == nil)
        #expect(rules.rule(forPath: URL(fileURLWithPath: "/"), home: home)?.id == "purgeable")
        #expect(rules.rule(forPath: URL(fileURLWithPath: "/Applications"), home: home) == nil)
    }

    @Test func protectedEntries() {
        let rules = CleanupRules.shared
        #expect(rules.isProtected(home.appendingPathComponent("Library/Caches/com.apple.bird"), home: home))
        #expect(rules.isProtected(home.appendingPathComponent("Library/Caches/CloudKit/x"), home: home))
        #expect(rules.isProtected(home.appendingPathComponent("Library/Caches/com.apple.nsurlsessiond"), home: home))
        #expect(!rules.isProtected(home.appendingPathComponent("Library/Caches/com.apple.Safari"), home: home))
    }

    @Test func globPathsMatchComponentWise() {
        let rules = CleanupRules.shared
        let docker = home.appendingPathComponent("Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw")
        #expect(rules.rule(forPath: docker, home: home)?.id == "dev.dockerDesktop")
        let other = home.appendingPathComponent("Library/Containers/com.docker.docker/Data/vms/0/data/other.raw")
        #expect(rules.rule(forPath: other, home: home)?.id != "dev.dockerDesktop")
        let dmg = home.appendingPathComponent("Downloads/Thing.dmg")
        #expect(rules.rule(forPath: dmg, home: home)?.id == "oldInstallers")
    }

    @Test func expandResolvesGlobsAgainstFileSystem() {
        let fs: MockFileSystem = [
            "/Users/test/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw": .file(size: 10),
            "/Users/test/Library/Containers/com.docker.docker/Data/vms/1/data/Docker.raw": .file(size: 20),
            "/Users/test/Library/Containers/com.docker.docker/Data/vms/2/data/other": .file(size: 1),
        ]
        let rules = CleanupRules.shared
        let urls = rules.expand("Library/Containers/com.docker.docker/Data/vms/*/data/Docker.raw",
                                home: home, fileSystem: fs)
        #expect(Set(urls.map(\.path)) == [
            "/Users/test/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw",
            "/Users/test/Library/Containers/com.docker.docker/Data/vms/1/data/Docker.raw",
        ])
        #expect(rules.expand(".ollama/models", home: home, fileSystem: fs).isEmpty)
        #expect(rules.expand("/Users", home: home, fileSystem: fs).map(\.path) == ["/Users"])
    }

    @Test func decodesFromJSON() throws {
        let json = """
        [{"id":"x","category":"cleanup.logs","relativePaths":["Library/Logs"],"risk":"caution","description":"d"}]
        """
        let rules = try CleanupRules(data: Data(json.utf8))
        #expect(rules.rules.count == 1)
        #expect(rules.rule(id: "x")?.risk == .caution)
        let encoded = try JSONEncoder().encode(rules.rules)
        let decoded = try JSONDecoder().decode([CleanupRule].self, from: encoded)
        #expect(decoded == rules.rules)
    }

    @Test func simpleGlob() {
        #expect(SimpleGlob("*.dmg").matches("a.dmg"))
        #expect(!SimpleGlob("*.dmg").matches("dir/a.dmg"))
        #expect(SimpleGlob("**/a.dmg").matches("dir/sub/a.dmg"))
        #expect(SimpleGlob("a?c").matches("abc"))
        #expect(!SimpleGlob("a?c").matches("a/c"))
    }
}
