import Foundation
import Testing
import CleanerCore
import CleanerCoreTesting
@testable import ProtectionModule

@Suite("ScanScopeResolver")
struct ScanScopeResolverTests {
    let home = URL(fileURLWithPath: "/Users/test")
    let recent = testNow.addingTimeInterval(-2 * 86_400)
    let old = testNow.addingTimeInterval(-30 * 86_400)

    var fs: MockFileSystem {
        [
            "/Users/test/Library/LaunchAgents/com.user.plist": .file(launchdPlist(program: "/Users/test/bin/agent")),
            "/Users/test/bin/agent": .file(size: 10),
            "/Library/LaunchAgents/com.vendor.plist": .file(launchdPlist(arguments: ["/usr/local/bin/tool", "-d"])),
            "/Library/LaunchAgents/com.gone.plist": .file(launchdPlist(program: "/opt/gone")),
            "/Library/LaunchAgents/notes.txt": .file("ignored"),
            "/usr/local/bin/tool": .file(size: 10),
            "/Users/test/Downloads/a": .file(size: 1),
            "/Users/test/Desktop": .directory,
            "/Applications/New.app": .package(modified: recent),
            "/Applications/Old.app": .package(modified: old),
            "/Applications/Weird.app": .file(size: 1, modified: recent),
            "/Users/test/Applications/Mine.app": .package(modified: recent),
            "/Volumes/Data/file": .file(size: 1),
            "/Volumes/Macintosh HD": .symlink(to: "/"),
            "/Volumes/.timemachine/x": .file(size: 1),
            "/Volumes/Backup.backupbundle/x": .file(size: 1),
            "/Volumes/Protected/x": .file(size: 1),
        ]
    }

    private func roots(_ scope: ScanScope, processes: [URL] = []) async -> [String] {
        let protected = ProtectedPaths(prefixes: [URL(fileURLWithPath: "/Volumes/Protected")])
        let resolver = ScanScopeResolver(fileSystem: fs, runningProcesses: StubProcesses(paths: processes),
                                         protectedPaths: protected)
        return await resolver.roots(for: scope, home: home, now: testNow).map(\.path)
    }

    @Test func quick() async {
        let roots = await roots(.quick, processes: [URL(fileURLWithPath: "/Users/test/bin/agent"),
                                                    URL(fileURLWithPath: "/no/such/process")])
        #expect(roots == [
            "/Applications/New.app",
            "/Library/LaunchAgents",
            "/Users/test/Applications/Mine.app",
            "/Users/test/Desktop",
            "/Users/test/Downloads",
            "/Users/test/Library/LaunchAgents",
            "/Users/test/bin/agent",
            "/usr/local/bin/tool",
        ])
    }

    @Test func normalCollapsesNestedRoots() async {
        let roots = await roots(.normal)
        #expect(roots == ["/Applications", "/Library/LaunchAgents", "/Users/test", "/usr/local"])
    }

    @Test func deepAddsVolumes() async {
        let roots = await roots(.deep)
        #expect(roots == ["/Applications", "/Library/LaunchAgents", "/Users/test", "/Volumes/Data", "/usr/local"])
    }

    @Test func missingRootsAreSkipped() async {
        let resolver = ScanScopeResolver(fileSystem: MockFileSystem([:]), runningProcesses: nil, protectedPaths: .none)
        let roots = await resolver.roots(for: .deep, home: home, now: testNow)
        #expect(roots.map(\.path) == ["/Users/test"])
    }

    @Test func protectedRootsAreDropped() async {
        let resolver = ScanScopeResolver(fileSystem: fs, runningProcesses: nil,
                                         protectedPaths: ProtectedPaths(prefixes: [URL(fileURLWithPath: "/usr")]))
        let roots = await resolver.roots(for: .normal, home: home, now: testNow)
        #expect(!roots.map(\.path).contains("/usr/local"))
    }

    @Test func deduplication() {
        let urls = ["/a/b", "/a", "/a/b/c", "/ab", "/a"].map { URL(fileURLWithPath: $0) }
        #expect(ScanScopeResolver.deduplicated(urls).map(\.path) == ["/a", "/ab"])
    }
}
