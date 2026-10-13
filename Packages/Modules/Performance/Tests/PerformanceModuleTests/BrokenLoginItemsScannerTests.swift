import Foundation
import Testing
import CleanerCore
import CleanerCoreTesting
@testable import PerformanceModule

@Suite("BrokenLoginItemsScanner")
struct BrokenLoginItemsScannerTests {
    let scanner = BrokenLoginItemsScanner()
    let modified = Date(timeIntervalSince1970: 1_700_000_000)

    var fs: MockFileSystem {
        [
            "/Users/test/Library/LaunchAgents/com.gone.agent.plist": .data(
                launchdPlistData(label: "com.gone.agent", program: "~/Library/Gone/agent"), modified: modified),
            "/Users/test/Library/LaunchAgents/com.ok.agent.plist": launchdPlist(
                label: "com.ok.agent", program: "/usr/bin/true"),
            "/usr/bin/true": .file(size: 1),
            "/Library/LaunchAgents/com.vendor.missing.plist": launchdPlist(
                label: "com.vendor.missing", programArguments: ["/Applications/Vendor.app/Contents/MacOS/v"]),
            "/Library/LaunchDaemons/com.daemon.missing.plist": launchdPlist(
                label: "com.daemon.missing", program: "/opt/daemon"),
            "/Library/LaunchDaemons/com.daemon.ok.plist": launchdPlist(
                label: "com.daemon.ok", program: "/Library/PrivilegedHelperTools/com.daemon.ok"),
            "/Library/PrivilegedHelperTools/com.daemon.ok": .file(size: 1),
        ]
    }

    @Test func metadata() {
        #expect(BrokenLoginItemsScanner.id == "performance.brokenLoginItems")
        #expect(scanner.id == "performance.brokenLoginItems")
        #expect(scanner.module == .performance)
        #expect(scanner.displayName == "Broken Login Items")
        let all = PerformanceScanners.all()
        #expect(all.map { type(of: $0).id } == ["performance.brokenLoginItems"])
        #expect(all.allSatisfy { $0.module == .performance })
    }

    @Test func emitsOnlyBrokenPlists() async throws {
        let findings = try await collect(scanner, context(fs))
        #expect(findings.paths == [
            "/Users/test/Library/LaunchAgents/com.gone.agent.plist",
            "/Library/LaunchAgents/com.vendor.missing.plist",
            "/Library/LaunchDaemons/com.daemon.missing.plist",
        ])
        #expect(findings.allSatisfy { $0.category.id == "performance.brokenLoginItems" })
        #expect(findings.allSatisfy { $0.category.module == .performance })
        #expect(findings.allSatisfy { $0.scannerID == "performance.brokenLoginItems" })
        #expect(findings.allSatisfy { $0.risk == .safe })
        #expect(findings.allSatisfy { !$0.isDirectory })
        let gone = try #require(findings.first { $0.path.lastPathComponent == "com.gone.agent.plist" })
        #expect(gone.detail == "com.gone.agent points to a missing program: ~/Library/Gone/agent")
        #expect(gone.modifiedAt == modified)
        #expect(gone.sizeBytes > 0)
    }

    @Test func ignoreListIsRespected() async throws {
        let findings = try await collect(scanner, context(fs, ignore: IgnoreList(globs: ["com.daemon.*"])))
        #expect(findings.paths == [
            "/Users/test/Library/LaunchAgents/com.gone.agent.plist",
            "/Library/LaunchAgents/com.vendor.missing.plist",
        ])
    }

    @Test func runsThroughScanCoordinator() async throws {
        let coordinator = ScanCoordinator(scanners: PerformanceScanners.all())
        var findings: [Finding] = []
        var summary: ScanSummary?
        var finished: (String, Int)?
        for await event in await coordinator.run(context(fs)) {
            switch event {
            case .finding(let finding): findings.append(finding)
            case .finished(let id, let count, _): finished = (id, count)
            case .completed(let s): summary = s
            case .failed(let id, let message): Issue.record("\(id) failed: \(message)")
            default: break
            }
        }
        #expect(findings.count == 3)
        #expect(finished?.0 == "performance.brokenLoginItems")
        #expect(finished?.1 == 3)
        #expect(summary?.totalFindings == 3)
        #expect(summary?.byCategory.keys.sorted() == ["performance.brokenLoginItems"])
    }

    @Test func coordinatorDropsProtectedPaths() async throws {
        let protected = ProtectedPaths(prefixes: [URL(fileURLWithPath: "/Library/LaunchDaemons")])
        let coordinator = ScanCoordinator(scanners: PerformanceScanners.all())
        var findings: [Finding] = []
        for await event in await coordinator.run(context(fs, protected: protected)) {
            if case .finding(let finding) = event { findings.append(finding) }
        }
        #expect(findings.paths == [
            "/Users/test/Library/LaunchAgents/com.gone.agent.plist",
            "/Library/LaunchAgents/com.vendor.missing.plist",
        ])
    }

    @Test func nothingBrokenYieldsNothing() async throws {
        let findings = try await collect(scanner, context([
            "/Users/test/Library/LaunchAgents/com.ok.plist": launchdPlist(label: "com.ok", program: "/bin/x"),
            "/bin/x": .file(size: 1),
        ]))
        #expect(findings.isEmpty)
    }
}
