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
