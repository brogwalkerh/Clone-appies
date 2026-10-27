import Foundation
import Testing
@testable import HelperProtocol

@Suite("HelperRequestValidator")
struct ValidatorTests {
    let validator = HelperRequestValidator()

    // MARK: callerHome

    @Test("accepts homes under /Users and the root home", arguments: [
        "/Users/alice", "/Users/alice.b-c_d", "/Users/Shared/Deep/Nested", "/var/root",
    ])
    func acceptsValidHomes(home: String) throws {
        try validator.validate(request(.ping, home: home))
    }

    @Test("rejects invalid homes", arguments: [
        "", "Users/alice", "/Users", "/Users/", "/Users/alice/", "/Users/../etc", "/Users/alice/..",
        "/Users//alice", "/Users/./alice", "/tmp/alice", "/private/var/root", "/var/root/", "/var", "/",
        "/Users/alice\0",
    ])
    func rejectsInvalidHomes(home: String) {
        #expect(throws: HelperValidationError.invalidHome(home)) {
            try validator.validate(request(.ping, home: home))
        }
    }

    @Test func homeIsValidatedForEveryOperation() {
        for operation in HelperOperation.allSamples {
            #expect(throws: HelperValidationError.invalidHome("/tmp")) {
                try validator.validate(request(operation, home: "/tmp"))
            }
        }
    }

    // MARK: removeSystemCache

    @Test("accepts cache paths strictly under the allowed roots", arguments: [
        "/Library/Caches/com.example.app",
        "/Library/Caches/com.example.app/Data",
        "/private/var/folders/zz/zyxvpxvq6csfxvn_n0000000000000/C/com.example.app",
    ])
    func acceptsCachePaths(path: String) throws {
        try validator.validate(request(.removeSystemCache(path: path)))
    }

    @Test("rejects cache paths outside the allowed roots", arguments: [
        "/Library/Caches", "/private/var/folders", "/Library/CachesX/foo", "/System/Library/Caches/foo",
        "/var/folders/zz/foo", "/Users/alice/Library/Caches/foo", "/private/var/db/foo", "/Library",
    ])
    func rejectsOutsideRoots(path: String) {
        #expect(throws: HelperValidationError.outsideAllowedRoot(path)) {
            try validator.validate(request(.removeSystemCache(path: path)))
        }
    }

    @Test("rejects malformed cache paths", arguments: [
        "", "Library/Caches/foo", "/Library/Caches/", "/Library/Caches/foo/", "/Library/Caches/../foo",
        "/Library/Caches/foo/..", "/Library/Caches/foo/../bar", "/Library/Caches//foo", "/Library/Caches/./foo",
        "/Library/Caches/foo\0", "/",
    ])
    func rejectsMalformedCachePaths(path: String) {
        #expect(throws: HelperValidationError.invalidPath(path)) {
            try validator.validate(request(.removeSystemCache(path: path)))
        }
    }

    @Test func rejectsSymlinkedCachePath() {
        let link = "/Library/Caches/com.example.link"
        let strict = HelperRequestValidator(isSymlink: { $0 == link })
        #expect(throws: HelperValidationError.invalidPath(link)) {
            try strict.validate(request(.removeSystemCache(path: link)))
        }
        // The same validator still accepts a non-link sibling.
        #expect(throws: Never.self) {
            try strict.validate(request(.removeSystemCache(path: "/Library/Caches/com.example.real")))
        }
    }

    @Test func symlinkCheckIsOnlyConsultedForCachePaths() throws {
        let paranoid = HelperRequestValidator(isSymlink: { _ in true })
        for operation in HelperOperation.allSamples {
            if case .removeSystemCache = operation { continue }
            try paranoid.validate(request(operation))
        }
    }

    @Test func fileManagerSymlinkCheckDetectsRealLinks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("helper-protocol-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("target")
        let link = dir.appendingPathComponent("link")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(HelperRequestValidator.fileManagerSymlinkCheck(link.path))
        #expect(!HelperRequestValidator.fileManagerSymlinkCheck(target.path))
        #expect(!HelperRequestValidator.fileManagerSymlinkCheck(dir.appendingPathComponent("missing").path))
    }

    // MARK: reindexSpotlight

    @Test("accepts root and top-level mounted volumes", arguments: ["/", "/Volumes/Data", "/Volumes/My Disk"])
    func acceptsVolumes(volume: String) throws {
        try validator.validate(request(.reindexSpotlight(volume: volume)))
    }

    @Test("rejects other volume strings", arguments: [
        "", "/Volumes", "/Volumes/", "/Volumes/Data/", "/Volumes/Data/sub", "/Volumes/..", "/Volumes/.",
        "/Volumes//Data", "Volumes/Data", "/Users", "//", "/System/Volumes/Data",
    ])
    func rejectsVolumes(volume: String) {
        #expect(throws: HelperValidationError.invalidVolume(volume)) {
            try validator.validate(request(.reindexSpotlight(volume: volume)))
        }
    }

    // MARK: setLaunchDaemonEnabled

    @Test("accepts well-formed third-party labels", arguments: [
        "com.example.daemon", "foo_bar-1", "a", "com.apple-lookalike.x", "org.apple.not-apple",
    ])
    func acceptsLabels(label: String) throws {
        try validator.validate(request(.setLaunchDaemonEnabled(label: label, enabled: true)))
        try validator.validate(request(.setLaunchDaemonEnabled(label: label, enabled: false)))
    }

    @Test("rejects malformed or Apple labels", arguments: [
        "", "com.apple.", "com.apple.mDNSResponder", "COM.APPLE.foo", "foo bar", "foo;rm -rf /", "foo/bar",
        "../foo", "foo\n", "föö", "system/foo", "$(x)",
    ])
    func rejectsLabels(label: String) {
        #expect(throws: HelperValidationError.invalidLabel(label)) {
            try validator.validate(request(.setLaunchDaemonEnabled(label: label, enabled: true)))
        }
    }

    // MARK: thinLocalSnapshots

    @Test("accepts positive byte counts", arguments: [Int64(1), Int64(1_000_000), Int64.max])
    func acceptsPositiveBytes(bytes: Int64) throws {
        try validator.validate(request(.thinLocalSnapshots(bytesToFree: bytes)))
    }

    @Test("rejects non-positive byte counts", arguments: [Int64(0), Int64(-1), Int64.min])
    func rejectsNonPositiveBytes(bytes: Int64) {
        #expect(throws: HelperValidationError.self) {
            try validator.validate(request(.thinLocalSnapshots(bytesToFree: bytes)))
        }
    }

    // MARK: argument-less operations

    @Test func everySampleValidates() throws {
        for operation in HelperOperation.allSamples {
            try validator.validate(request(operation))
        }
        for interval in PeriodicInterval.allCases {
            try validator.validate(request(.runPeriodicScripts(interval)))
        }
    }

    @Test func errorsDescribeThemselves() {
        #expect(HelperValidationError.invalidHome("/x").description.contains("/x"))
        #expect(HelperValidationError.outsideAllowedRoot("/y").description.contains("/y"))
    }
}
