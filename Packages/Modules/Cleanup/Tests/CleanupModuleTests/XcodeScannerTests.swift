import Foundation
import Testing
import CleanerCore
import CleanerCoreTesting
@testable import CleanupModule

@Suite("XcodeScanner")
struct XcodeScannerTests {
    let scanner = XcodeScanner()

    var fs: MockFileSystem {
        [
            "/Users/test/Library/Developer/Xcode/DerivedData/App-abc/Build/x.o": .file(size: 1_000),
            "/Users/test/Library/Developer/Xcode/DerivedData/App-abc/Index/i": .file(size: 500),
            "/Users/test/Library/Developer/Xcode/DerivedData/ModuleCache.noindex/a.pcm": .file(size: 250),
            "/Users/test/Library/Developer/Xcode/Archives/2026-08-01/App.xcarchive": .package(modified: daysAgo(70)),
            "/Users/test/Library/Developer/Xcode/Archives/2026-08-01/App.xcarchive/dSYMs/App.dSYM/x": .file(size: 4_000),
            "/Users/test/Library/Developer/Xcode/iOS DeviceSupport/17.5 (21F79) arm64e/Symbols/dyld": .file(size: 8_000),
            "/Users/test/Library/Developer/Xcode/watchOS DeviceSupport/10.0/Symbols/x": .file(size: 300),
            "/Users/test/Library/Developer/Xcode/UserData/prefs": .file(size: 1),
            "/Users/test/Library/Developer/CoreSimulator/Caches/dyld/cache": .file(size: 16_000),
            "/Users/test/Library/Developer/CoreSimulator/Devices/ABC/data/x": .file(size: 1),
            "/Users/test/Library/Caches/com.apple.dt.Xcode/Downloads/stub.bin": .file(size: 2_000),
        ]
    }

    @Test func derivedDataChildrenAreSafe() async throws {
        let findings = try await collect(scanner, context(fs))
        let app = try #require(findings.named("App-abc"))
        #expect(app.category.id == "cleanup.xcode")
        #expect(app.risk == .safe)
        #expect(app.sizeBytes == 1_500)
        #expect(app.isDirectory)
        #expect(findings.named("ModuleCache.noindex")?.sizeBytes == 250)
        #expect(findings.at("/Users/test/Library/Developer/Xcode/DerivedData") == nil)
    }

    @Test func archivesAreRiskyWithPackageSizes() async throws {
        let findings = try await collect(scanner, context(fs))
        let archive = try #require(findings.named("2026-08-01"))
        #expect(archive.risk == .risky)
        #expect(archive.detail?.hasPrefix("Contains dSYMs for shipped builds") == true)
        #expect(archive.sizeBytes == 4_000)   // includes package contents
    }

    @Test func deviceSupportAndCachesAreSafe() async throws {
        let findings = try await collect(scanner, context(fs))
        #expect(findings.named("17.5 (21F79) arm64e")?.risk == .safe)
        #expect(findings.named("17.5 (21F79) arm64e")?.sizeBytes == 8_000)
        #expect(findings.named("10.0")?.sizeBytes == 300)
        let simCaches = try #require(findings.at("/Users/test/Library/Developer/CoreSimulator/Caches"))
        #expect(simCaches.risk == .safe)
        #expect(simCaches.sizeBytes == 16_000)
        let xcodeCaches = try #require(findings.at("/Users/test/Library/Caches/com.apple.dt.Xcode"))
        #expect(xcodeCaches.sizeBytes == 2_000)
        #expect(findings.named("UserData") == nil)
        #expect(findings.named("Devices") == nil)
        #expect(findings.count == 7)
    }

    @Test func missingParentsYieldNothing() async throws {
        let fs: MockFileSystem = ["/Users/test/Library/Developer/Xcode/UserData/x": .file(size: 1)]
        let findings = try await collect(scanner, context(fs))
        #expect(findings.isEmpty)
    }

    @Test func ignoreListIsRespected() async throws {
        let ignore = IgnoreList(paths: [URL(fileURLWithPath: "/Users/test/Library/Developer/Xcode/Archives")])
        let findings = try await collect(scanner, context(fs, ignore: ignore))
        #expect(findings.named("2026-08-01") == nil)
        #expect(findings.named("App-abc") != nil)
    }
}
