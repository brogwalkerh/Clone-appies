import Foundation
import Testing
import CleanerCore
import CleanerCoreTesting
@testable import CleanupModule

@Suite("AIToolLeftoversScanner")
struct AIToolLeftoversScannerTests {
    let scanner = AIToolLeftoversScanner()

    var fs: MockFileSystem {
        [
            "/Users/test/.ollama/models/blobs/sha256-1": .file(size: 120_000, modified: daysAgo(30)),
            "/Users/test/.ollama/models/manifests/llama3/latest": .file(size: 100),
            "/Users/test/.cache/huggingface/hub/models--bert/blobs/a": .file(size: 100_000),
            "/Users/test/.cache/lm-studio/models/x.gguf": .file(size: 80_000),
            "/Users/test/.lmstudio/models/y.gguf": .file(size: 70_000),
            "/Users/test/.cache/torch/hub/checkpoints/w.pth": .file(size: 5_000),
            "/Users/test/.cache/pip/http/blob": .file(size: 3_000),
            "/Users/test/.cache/other/thing": .file(size: 1),
            "/Users/test/Library/Caches/com.apple.dt.Xcode/PredictiveCodeCompletion/model.bin": .file(size: 30_000),
            "/Users/test/Library/Caches/com.apple.dt.Xcode/Downloads/stub": .file(size: 2_000),
        ]
    }

    @Test func existingPathsAreReportedWithRuleRisk() async throws {
        let findings = try await collect(scanner, context(fs))
        #expect(findings.paths == [
            "/Users/test/.ollama/models",
            "/Users/test/.cache/huggingface",
            "/Users/test/.lmstudio/models",
            "/Users/test/.cache/lm-studio",
            "/Users/test/.cache/torch",
            "/Users/test/.cache/pip",
        ])
        #expect(findings.allSatisfy { $0.category.id == "cleanup.aiLeftovers" && $0.isDirectory })
        let ollama = try #require(findings.at("/Users/test/.ollama/models"))
        #expect(ollama.risk == .risky)
        #expect(ollama.sizeBytes == 120_100)
        #expect(ollama.detail?.hasPrefix("Downloaded Ollama models, re-download to restore") == true)
        #expect(findings.at("/Users/test/.cache/huggingface")?.risk == .caution)
        #expect(findings.at("/Users/test/.cache/huggingface")?.sizeBytes == 100_000)
        #expect(findings.at("/Users/test/.cache/lm-studio")?.risk == .risky)
        #expect(findings.at("/Users/test/.lmstudio/models")?.risk == .risky)
        #expect(findings.at("/Users/test/.cache/torch")?.risk == .safe)
        #expect(findings.at("/Users/test/.cache/pip")?.risk == .safe)
        // Xcode's predictive-completion cache belongs to the cleanup.xcode finding, not this scanner.
        #expect(findings.named("PredictiveCodeCompletion") == nil)
        #expect(findings.named("com.apple.dt.Xcode") == nil)
    }

    @Test func missingPathsYieldNothing() async throws {
        let fs: MockFileSystem = ["/Users/test/.cache/other/thing": .file(size: 1)]
        let findings = try await collect(scanner, context(fs))
        #expect(findings.isEmpty)
    }

    @Test func ignoreListIsRespected() async throws {
        let ignore = IgnoreList(paths: [URL(fileURLWithPath: "/Users/test/.ollama")])
        let findings = try await collect(scanner, context(fs, ignore: ignore))
        #expect(findings.at("/Users/test/.ollama/models") == nil)
        #expect(findings.at("/Users/test/.cache/huggingface") != nil)
    }
}
