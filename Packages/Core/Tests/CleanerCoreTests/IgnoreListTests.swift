import Foundation
import Testing
@testable import CleanerCore

@Suite("IgnoreList")
struct IgnoreListTests {
    @Test func emptyMatchesNothing() {
        #expect(!IgnoreList.empty.contains(URL(fileURLWithPath: "/anything")))
    }

    @Test func exactAndDescendantPaths() {
        let list = IgnoreList(paths: [URL(fileURLWithPath: "/Users/me/Keep")])
        #expect(list.contains(URL(fileURLWithPath: "/Users/me/Keep")))
        #expect(list.contains(URL(fileURLWithPath: "/Users/me/Keep/sub/file")))
        #expect(!list.contains(URL(fileURLWithPath: "/Users/me/Keeper")))
        #expect(!list.contains(URL(fileURLWithPath: "/Users/me")))
    }

    @Test func addingReturnsNewList() {
        let base = IgnoreList.empty
        let added = base.adding(URL(fileURLWithPath: "/tmp/x"))
        #expect(!base.contains(URL(fileURLWithPath: "/tmp/x")))
        #expect(added.contains(URL(fileURLWithPath: "/tmp/x")))
    }

    @Test func starDoesNotCrossSlash() {
        let list = IgnoreList(globs: ["/Users/*/Library/Caches"])
        #expect(list.contains(URL(fileURLWithPath: "/Users/me/Library/Caches")))
        #expect(!list.contains(URL(fileURLWithPath: "/Users/me/x/Library/Caches")))
    }

    @Test func doubleStarCrossesSlash() {
        let list = IgnoreList(globs: ["/Users/**/Caches/*.db"])
        #expect(list.contains(URL(fileURLWithPath: "/Users/me/Library/Caches/a.db")))
        #expect(list.contains(URL(fileURLWithPath: "/Users/Caches/a.db")))
        #expect(!list.contains(URL(fileURLWithPath: "/Users/me/Library/Caches/sub/a.db")))
        #expect(!list.contains(URL(fileURLWithPath: "/Users/me/Library/Caches/a.txt")))
    }

    @Test func trailingDoubleStar() {
        let list = IgnoreList(globs: ["/opt/**"])
        #expect(list.contains(URL(fileURLWithPath: "/opt/a")))
        #expect(list.contains(URL(fileURLWithPath: "/opt/a/b/c")))
        #expect(!list.contains(URL(fileURLWithPath: "/optimal/a")))
    }

    @Test func questionMark() {
        let list = IgnoreList(globs: ["/tmp/file?.log"])
        #expect(list.contains(URL(fileURLWithPath: "/tmp/file1.log")))
        #expect(!list.contains(URL(fileURLWithPath: "/tmp/file12.log")))
        #expect(!list.contains(URL(fileURLWithPath: "/tmp/file.log")))
    }

    @Test func bareNamePatternMatchesLastComponent() {
        let list = IgnoreList(globs: ["*.log"])
        #expect(list.contains(URL(fileURLWithPath: "/var/log/system.log")))
        #expect(!list.contains(URL(fileURLWithPath: "/var/log/system.txt")))
    }

    @Test func literalMatch() {
        #expect(GlobMatcher("/a/b").matches("/a/b"))
        #expect(!GlobMatcher("/a/b").matches("/a/bc"))
        #expect(GlobMatcher("**").matches("/anything/at/all"))
        #expect(GlobMatcher("/a/**/z").matches("/a/z"))
        #expect(GlobMatcher("/a/**/z").matches("/a/b/c/z"))
    }

    @Test func codableRoundTrip() throws {
        let list = IgnoreList(paths: [URL(fileURLWithPath: "/x")], globs: ["*.tmp"])
        let data = try JSONEncoder().encode(list)
        let decoded = try JSONDecoder().decode(IgnoreList.self, from: data)
        #expect(decoded == list)
    }
}
