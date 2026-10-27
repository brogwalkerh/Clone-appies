import Foundation
import Testing
import CleanerCore
import CleanerCoreTesting
@testable import CleanupModule

@Suite("DevToolCachesScanner")
struct DevToolCachesScannerTests {
    let scanner = DevToolCachesScanner()

    var fs: MockFileSystem {
        [
            "/Users/test/Library/Caches/Homebrew/downloads/a.tar.gz": .file(size: 5_000),
            "/Users/test/Library/Caches/Homebrew/Cask/b.zip": .file(size: 30_000),
            "/Users/test/.npm/_cacache/index-v5/x": .file(size: 1_000),
            "/Users/test/.cache/yarn/v6/y": .file(size: 2_000),
            "/Users/test/.gradle/caches/modules-2/z": .file(size: 3_000),
            "/Users/test/.m2/repository/org/x.jar": .file(size: 4_000),
            "/Users/test/.cargo/registry/cache/github/c.crate": .file(size: 500),
            "/Users/test/.cargo/registry/src/github/src.rs": .file(size: 1),
            "/Users/test/Library/Caches/CocoaPods/Pods/p": .file(size: 600),
            "/Users/test/Library/Caches/org.swift.swiftpm/repositories/r": .file(size: 700),
            "/Users/test/Library/Caches/pip/http/h": .file(size: 800),
            "/Users/test/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw": .file(size: 1_000_000, modified: daysAgo(1)),
            "/Users/test/Library/Containers/com.docker.docker/Data/vms/0/data/other": .file(size: 1),
        ]
    }

    @Test func knownCachesAreReported() async throws {
        let findings = try await collect(scanner, context(fs))
        #expect(findings.paths == [
            "/Users/test/Library/Caches/Homebrew",
            "/Users/test/.npm/_cacache",
            "/Users/test/.cache/yarn",
            "/Users/test/.gradle/caches",
            "/Users/test/.m2/repository",
            "/Users/test/.cargo/registry/cache",
            "/Users/test/Library/Caches/CocoaPods",
            "/Users/test/Library/Caches/org.swift.swiftpm",
            "/Users/test/Library/Caches/pip",
            "/Users/test/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw",
        ])
        #expect(findings.allSatisfy { $0.category.id == "cleanup.devCaches" && $0.scannerID == "cleanup.devCaches" })
        let brew = try #require(findings.named("Homebrew"))
        #expect(brew.risk == .safe)
        #expect(brew.sizeBytes == 35_000)
        #expect(brew.isDirectory)
        #expect(findings.at("/Users/test/.m2/repository")?.risk == .caution)
        #expect(findings.at("/Users/test/.gradle/caches")?.risk == .caution)
        #expect(findings.at("/Users/test/.cargo/registry/cache")?.sizeBytes == 500)
        let docker = try #require(findings.named("Docker.raw"))
        #expect(docker.risk == .risky)
        #expect(!docker.isDirectory)
        #expect(docker.sizeBytes == 1_000_000)
        #expect(docker.modifiedAt == daysAgo(1))
        #expect(docker.detail?.contains("Docker") == true)
    }

    @Test func missingPathsYieldNothing() async throws {
        let fs: MockFileSystem = ["/Users/test/.cargo/registry/src/x": .file(size: 1)]
        let findings = try await collect(scanner, context(fs))
        #expect(findings.isEmpty)
    }

    @Test func ignoreListAndProtectedPathsAreRespected() async throws {
        let ignore = IgnoreList(paths: [URL(fileURLWithPath: "/Users/test/Library/Caches/Homebrew")])
        let protected = ProtectedPaths(prefixes: [URL(fileURLWithPath: "/Users/test/Library/Containers/com.docker.docker")])
        let findings = try await collect(scanner, context(fs, ignore: ignore, protected: protected))
        #expect(findings.named("Homebrew") == nil)
        #expect(findings.named("Docker.raw") == nil)
        #expect(findings.named("_cacache") != nil)
    }
}
