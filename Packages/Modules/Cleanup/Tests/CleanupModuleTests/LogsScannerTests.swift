import Foundation
import Testing
import CleanerCore
import CleanerCoreTesting
@testable import CleanupModule

@Suite("LogsScanner")
struct LogsScannerTests {
    let scanner = LogsScanner()

    var fs: MockFileSystem {
        [
            "/Users/test/Library/Logs/install.log": .file(size: 100, modified: daysAgo(5)),
            "/Users/test/Library/Logs/com.example.chat/chat.log": .file(size: 10),
            "/Users/test/Library/Logs/com.example.chat/chat.log.1": .file(size: 20),
            "/Users/test/Library/Logs/com.example.chat/chat.log.2.gz": .file(size: 30),
            "/Users/test/Library/Logs/Homebrew/wget/01.configure": .file(size: 40),
            "/Users/test/Library/Logs/DiagnosticReports/App-2026-09-01.ips": .file(size: 500, modified: daysAgo(40)),
            "/Users/test/Library/Logs/DiagnosticReports/App.crash": .file(size: 600),
            "/Users/test/Library/Logs/DiagnosticReports/Retired/Old.ips": .file(size: 700),
            "/Users/test/Library/Logs/link.log": .symlink(to: "/Users/test/Library/Logs/install.log"),
            "/Users/test/Library/Containers/com.example.box/Data/Library/Logs/box.log": .file(size: 50),
            "/Users/test/Library/Containers/com.example.box/Data/Library/Logs/notes.txt": .file(size: 60),
        ]
    }

    @Test func logFilesAreSafeFindings() async throws {
        let findings = try await collect(scanner, context(fs))
        let logs = findings.filter { $0.category.id == "cleanup.logs" }
        #expect(logs.paths == [
            "/Users/test/Library/Logs/install.log",
            "/Users/test/Library/Logs/com.example.chat/chat.log",
            "/Users/test/Library/Logs/com.example.chat/chat.log.1",
            "/Users/test/Library/Logs/com.example.chat/chat.log.2.gz",
            "/Users/test/Library/Logs/Homebrew/wget/01.configure",
            "/Users/test/Library/Containers/com.example.box/Data/Library/Logs/box.log",
        ])
        #expect(logs.allSatisfy { $0.risk == .safe && !$0.isDirectory && $0.scannerID == "cleanup.logs" })
        let install = try #require(logs.named("install.log"))
        #expect(install.sizeBytes == 100)
        #expect(install.modifiedAt == daysAgo(5))
        #expect(install.detail?.isEmpty == false)
    }

    @Test func crashReportsAreSeparateCategory() async throws {
        let findings = try await collect(scanner, context(fs))
        let crashes = findings.filter { $0.category.id == "cleanup.crashReports" }
        #expect(crashes.paths == [
            "/Users/test/Library/Logs/DiagnosticReports/App-2026-09-01.ips",
            "/Users/test/Library/Logs/DiagnosticReports/App.crash",
            "/Users/test/Library/Logs/DiagnosticReports/Retired",
        ])
        let retired = try #require(crashes.named("Retired"))
        #expect(retired.isDirectory)
        #expect(retired.sizeBytes == 700)
        #expect(crashes.named("App-2026-09-01.ips")?.modifiedAt == daysAgo(40))
        #expect(crashes.allSatisfy { $0.risk == .safe })
        #expect(findings.at("/Users/test/Library/Logs/DiagnosticReports") == nil)
    }

    @Test func missingLogsDirectoryYieldsNothing() async throws {
        let fs: MockFileSystem = ["/Users/test/Library/Caches/x/y": .file(size: 1)]
        let findings = try await collect(scanner, context(fs))
        #expect(findings.isEmpty)
    }

    @Test func ignoreListIsRespected() async throws {
        let ignore = IgnoreList(paths: [URL(fileURLWithPath: "/Users/test/Library/Logs/com.example.chat")],
                                globs: ["*.ips"])
        let findings = try await collect(scanner, context(fs, ignore: ignore))
        #expect(findings.named("chat.log") == nil)
        #expect(findings.named("chat.log.1") == nil)
        #expect(findings.named("App-2026-09-01.ips") == nil)
        #expect(findings.named("App.crash") != nil)
        #expect(findings.named("install.log") != nil)
    }

    @Test func logRotationPatterns() {
        #expect(LogsScanner.isLogFile(URL(fileURLWithPath: "/a/app.log")))
        #expect(LogsScanner.isLogFile(URL(fileURLWithPath: "/a/app.log.3")))
        #expect(LogsScanner.isLogFile(URL(fileURLWithPath: "/a/app.log.2.gz")))
        #expect(LogsScanner.isLogFile(URL(fileURLWithPath: "/a/APP.LOG")))
        #expect(!LogsScanner.isLogFile(URL(fileURLWithPath: "/a/app.log.bak")))
        #expect(!LogsScanner.isLogFile(URL(fileURLWithPath: "/a/notes.txt")))
    }
}
