import Foundation
import Testing
@testable import CleanerCore

@Suite("ProtectedPaths")
struct ProtectedPathsTests {
    let paths = ProtectedPaths(prefixes: [
        URL(fileURLWithPath: "/usr"),
        URL(fileURLWithPath: "/private/var/db/"),
    ])

    @Test func prefixIsProtected() {
        #expect(paths.isProtected(URL(fileURLWithPath: "/usr")))
        #expect(paths.isProtected(URL(fileURLWithPath: "/usr/")))
        #expect(paths.isProtected(URL(fileURLWithPath: "/usr/lib/libc.so")))
        #expect(paths.isProtected(URL(fileURLWithPath: "/private/var/db/dslocal")))
    }

    @Test func componentAware() {
        #expect(!paths.isProtected(URL(fileURLWithPath: "/usrdata")))
        #expect(!paths.isProtected(URL(fileURLWithPath: "/usrdata/lib")))
        #expect(!paths.isProtected(URL(fileURLWithPath: "/private/var/dbx")))
        #expect(!paths.isProtected(URL(fileURLWithPath: "/private/var")))
        #expect(!paths.isProtected(URL(fileURLWithPath: "/")))
    }

    @Test func standardizesDotSegments() {
        #expect(paths.isProtected(URL(fileURLWithPath: "/home/../usr/lib")))
        #expect(paths.isProtected(URL(fileURLWithPath: "/usr/./bin")))
    }

    @Test func globsCoverTimeMachineBundles() {
        let tm = ProtectedPaths(prefixes: [], globs: ["/Volumes/*.backupbundle"])
        #expect(tm.isProtected(URL(fileURLWithPath: "/Volumes/Backups.backupbundle")))
        #expect(tm.isProtected(URL(fileURLWithPath: "/Volumes/Backups.backupbundle/bands/1")))
        #expect(!tm.isProtected(URL(fileURLWithPath: "/Volumes/Data/x.backupbundle")))
        #expect(!tm.isProtected(URL(fileURLWithPath: "/Volumes/Data")))
    }

    @Test func ancestorsOfProtectedPathsContainProtectedContent() {
        // Not "protected" for walking purposes, but removing them is refused.
        for ancestor in ["/", "/var", "/private/var"] {
            let url = URL(fileURLWithPath: ancestor)
            #expect(!paths.isProtected(url))
            #expect(paths.containsProtected(url))
        }
        #expect(paths.containsProtected(URL(fileURLWithPath: "/usr/lib")))
        #expect(!paths.containsProtected(URL(fileURLWithPath: "/private/var/dbx")))
        #expect(!paths.containsProtected(URL(fileURLWithPath: "/home/user/Downloads")))
        #expect(!ProtectedPaths.none.containsProtected(URL(fileURLWithPath: "/")))
    }

    @Test func privateAliasesCompareEqualWhetherOrNotThePathExists() {
        // Neither file exists; both spellings must still be protected.
        #expect(paths.isProtected(URL(fileURLWithPath: "/private/var/db/no-such-file-\(UUID().uuidString)")))
        #expect(paths.isProtected(URL(fileURLWithPath: "/var/db/no-such-file-\(UUID().uuidString)")))
        #expect(!paths.isProtected(URL(fileURLWithPath: "/private/variable")))
    }

    @Test func ancestorsOfGlobDirectoriesContainProtectedContent() {
        let tm = ProtectedPaths(prefixes: [], globs: ["/Volumes/*.backupbundle"])
        #expect(tm.containsProtected(URL(fileURLWithPath: "/Volumes")))
        #expect(tm.containsProtected(URL(fileURLWithPath: "/")))
        #expect(tm.containsProtected(URL(fileURLWithPath: "/Volumes/Backups.backupbundle")))
        #expect(!tm.containsProtected(URL(fileURLWithPath: "/Volumes/Data")))
    }

    @Test func defaultProtectsSystemDirectories() {
        #expect(ProtectedPaths.default.isProtected(URL(fileURLWithPath: "/usr/lib")))
        #expect(ProtectedPaths.default.isProtected(URL(fileURLWithPath: "/bin/sh")))
        #expect(!ProtectedPaths.default.isProtected(URL(fileURLWithPath: "/home/user/Downloads")))
    }

    @Test func codableRoundTrip() throws {
        let data = try JSONEncoder().encode(paths)
        let decoded = try JSONDecoder().decode(ProtectedPaths.self, from: data)
        #expect(decoded == paths)
    }
}
