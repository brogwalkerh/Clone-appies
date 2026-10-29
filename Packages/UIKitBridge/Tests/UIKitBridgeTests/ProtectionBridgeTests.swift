import CleanerCore
import CoreServices
import Foundation
import ProtectionModule
import Security
import XCTest
@testable import UIKitBridge

/// Pure parts of the Protection bridges: no FSEvents, no SQLite, no Security
/// calls, so these run on the macOS CI runner without Full Disk Access.
final class ProtectionBridgeTests: XCTestCase {
    // MARK: Quarantine attribute

    func testQuarantineParsesStandardFourFields() throws {
        let attribute = try XCTUnwrap(QuarantineAttribute.parse("0083;5f3e2b1c;Safari;7A1B2C3D-0000-4000-8000-000000000000"))
        XCTAssertEqual(attribute.flags, 0x83)
        XCTAssertEqual(attribute.date, Date(timeIntervalSince1970: 0x5f3e2b1c))
        XCTAssertEqual(attribute.agentName, "Safari")
        XCTAssertEqual(attribute.identifier, "7A1B2C3D-0000-4000-8000-000000000000")
        XCTAssertNil(attribute.originURL)
        XCTAssertEqual(attribute.downloadDescription, "Downloaded from Safari")
    }

    func testQuarantineParsesOriginURLInExtraField() throws {
        let attribute = try XCTUnwrap(QuarantineAttribute.parse("0081;64a1b2c3;Google Chrome;;https://example.com/dl/payload.dmg"))
        XCTAssertEqual(attribute.agentName, "Google Chrome")
        XCTAssertNil(attribute.identifier)   // empty fourth field
        XCTAssertEqual(attribute.originURL?.host(), "example.com")
        XCTAssertEqual(attribute.downloadDescription, "Downloaded from Google Chrome (example.com)")
    }

    func testQuarantineAgentFieldMayBeURL() throws {
        let attribute = try XCTUnwrap(QuarantineAttribute.parse("0001;0;https://files.example.org/x.pkg;"))
        XCTAssertNil(attribute.agentName)
        XCTAssertNil(attribute.date)   // zero timestamp means unknown
        XCTAssertEqual(attribute.originURL?.host(), "files.example.org")
        XCTAssertEqual(attribute.downloadDescription, "Downloaded from files.example.org")
    }

    func testQuarantineFlagsOnlyAndMalformed() throws {
        let bare = try XCTUnwrap(QuarantineAttribute.parse("0002"))
        XCTAssertEqual(bare.flags, 2)
        XCTAssertNil(bare.agentName)
        XCTAssertNil(bare.downloadDescription)
        XCTAssertNil(QuarantineAttribute.parse(""))
        XCTAssertNil(QuarantineAttribute.parse("not-hex;1;Safari"))
        XCTAssertNil(QuarantineAttribute.parse(";;;"))
    }

    // MARK: Debounce

    func testDebouncerSchedulesOnceAndScansAfterQuietWindow() {
        var debouncer = PathDebouncer(window: 2, capacity: 10)
        XCTAssertEqual(debouncer.record("/a", at: 0), .schedule)
        XCTAssertEqual(debouncer.record("/a", at: 0.5), .alreadyScheduled)
        XCTAssertEqual(debouncer.pendingCount, 1)

        // Timer armed at 0 fires at 2, but the path was touched at 0.5 → wait 0.5 more.
        XCTAssertEqual(debouncer.flush("/a", at: 2), .wait(0.5))
        XCTAssertEqual(debouncer.flush("/a", at: 2.5), .scan)
        XCTAssertEqual(debouncer.pendingCount, 0)
        XCTAssertEqual(debouncer.flush("/a", at: 3), .nothingPending)
        // A fresh event after a scan schedules again.
        XCTAssertEqual(debouncer.record("/a", at: 3), .schedule)
    }

    func testDebouncerToleratesEarlyTimer() {
        var debouncer = PathDebouncer(window: 2, capacity: 10)
        _ = debouncer.record("/a", at: 10)
        XCTAssertEqual(debouncer.flush("/a", at: 11.995), .scan)   // 5 ms early counts as quiet
    }

    func testDebouncerCapacityScansImmediatelyWithoutRecording() {
        var debouncer = PathDebouncer(window: 2, capacity: 2)
        XCTAssertEqual(debouncer.record("/a", at: 0), .schedule)
        XCTAssertEqual(debouncer.record("/b", at: 0), .schedule)
        XCTAssertEqual(debouncer.record("/c", at: 0), .scanImmediately)
        XCTAssertFalse(debouncer.isPending("/c"))
        XCTAssertEqual(debouncer.record("/a", at: 1), .alreadyScheduled)   // known paths still coalesce
        debouncer.cancel("/a")
        XCTAssertEqual(debouncer.record("/c", at: 1), .schedule)
    }

    // MARK: FSEvents flag triage

    func testEventDispositionFlags() {
        func flags(_ bits: Int...) -> FSEventStreamEventFlags {
            FSEventStreamEventFlags(bits.reduce(0, |))
        }
        XCTAssertEqual(ProtectionMonitor.disposition(for: flags(kFSEventStreamEventFlagItemCreated, kFSEventStreamEventFlagItemIsFile)), .scanFile)
        XCTAssertEqual(ProtectionMonitor.disposition(for: flags(kFSEventStreamEventFlagItemModified, kFSEventStreamEventFlagItemIsFile)), .scanFile)
        XCTAssertEqual(ProtectionMonitor.disposition(for: flags(kFSEventStreamEventFlagItemRenamed, kFSEventStreamEventFlagItemIsFile)), .scanFile)
        XCTAssertEqual(ProtectionMonitor.disposition(for: flags(kFSEventStreamEventFlagItemRemoved, kFSEventStreamEventFlagItemIsFile)), .ignore)
        // Removed + renamed in one coalesced event: the file may be back under this name.
        XCTAssertEqual(ProtectionMonitor.disposition(for: flags(kFSEventStreamEventFlagItemRemoved, kFSEventStreamEventFlagItemRenamed, kFSEventStreamEventFlagItemIsFile)), .scanFile)
        XCTAssertEqual(ProtectionMonitor.disposition(for: flags(kFSEventStreamEventFlagItemCreated, kFSEventStreamEventFlagItemIsDir)), .ignore)
        XCTAssertEqual(ProtectionMonitor.disposition(for: flags(kFSEventStreamEventFlagItemCreated, kFSEventStreamEventFlagItemIsSymlink)), .ignore)
        XCTAssertEqual(ProtectionMonitor.disposition(for: flags(kFSEventStreamEventFlagMustScanSubDirs)), .rescanDirectory)
        XCTAssertEqual(ProtectionMonitor.disposition(for: flags(kFSEventStreamEventFlagMustScanSubDirs, kFSEventStreamEventFlagItemIsDir)), .rescanDirectory)
        XCTAssertEqual(ProtectionMonitor.disposition(for: flags(kFSEventStreamEventFlagKernelDropped)), .rescanDirectory)
    }

    func testRenamedDirectoryIsWalked() {
        func flags(_ bits: Int...) -> FSEventStreamEventFlags {
            FSEventStreamEventFlags(bits.reduce(0, |))
        }
        // Foo.app moved into /Applications: one event, for the directory.
        XCTAssertEqual(ProtectionMonitor.disposition(for: flags(kFSEventStreamEventFlagItemRenamed, kFSEventStreamEventFlagItemIsDir)), .scanDirectoryTree)
        XCTAssertEqual(ProtectionMonitor.disposition(for: flags(kFSEventStreamEventFlagItemRenamed, kFSEventStreamEventFlagItemIsDir, kFSEventStreamEventFlagItemIsSymlink)), .ignore)
        XCTAssertEqual(ProtectionMonitor.disposition(for: flags(kFSEventStreamEventFlagItemRemoved, kFSEventStreamEventFlagItemIsDir)), .ignore)
        XCTAssertEqual(ProtectionMonitor.disposition(for: flags(kFSEventStreamEventFlagItemInodeMetaMod, kFSEventStreamEventFlagItemIsDir)), .ignore)
    }

    func testDirectoryWalkIsBoundedAndSkipsSymlinks() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("monitor-walk-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let app = root.appendingPathComponent("Foo.app", isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: macOS.appendingPathComponent("Foo"))
        try Data("y".utf8).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let link = app.appendingPathComponent("Contents/Link")
        try fm.createSymbolicLink(at: link, withDestinationURL: macOS)

        let files = ProtectionMonitor.regularFiles(under: app, fileSystem: LocalFileSystem(), protectedPaths: .none, limit: 100)
        XCTAssertEqual(Set(files.map { URL(fileURLWithPath: $0).lastPathComponent }), ["Foo", "Info.plist"])
        // Only "Contents" is examined: no files.
        XCTAssertEqual(ProtectionMonitor.regularFiles(under: app, fileSystem: LocalFileSystem(), protectedPaths: .none, limit: 1), [])
        XCTAssertEqual(ProtectionMonitor.regularFiles(under: link, fileSystem: LocalFileSystem(), protectedPaths: .none, limit: 100), [])
        XCTAssertEqual(ProtectionMonitor.regularFiles(under: app, fileSystem: LocalFileSystem(),
                                                      protectedPaths: ProtectedPaths(prefixes: [app]), limit: 100), [])
    }

    // MARK: Executable detection

    func testExecutableKindDetection() {
        XCTAssertEqual(FileInspector.ExecutableKind.detect(magic: [0xFE, 0xED, 0xFA, 0xCF, 0x00]), .machO)
        XCTAssertEqual(FileInspector.ExecutableKind.detect(magic: [0xCF, 0xFA, 0xED, 0xFE]), .machO)
        XCTAssertEqual(FileInspector.ExecutableKind.detect(magic: [0xCA, 0xFE, 0xBA, 0xBE]), .machO)
        XCTAssertEqual(FileInspector.ExecutableKind.detect(magic: [0x7F, 0x45, 0x4C, 0x46]), .elf)
        XCTAssertEqual(FileInspector.ExecutableKind.detect(magic: Array("MZ\u{90}\0".utf8)), .pe)
        XCTAssertEqual(FileInspector.ExecutableKind.detect(magic: Array("#!/bin/sh".utf8)), .script)
        XCTAssertNil(FileInspector.ExecutableKind.detect(magic: Array("%PDF".utf8)))
        XCTAssertNil(FileInspector.ExecutableKind.detect(magic: [0x7F]))
        XCTAssertNil(FileInspector.ExecutableKind.detect(magic: []))
        XCTAssertEqual(FileInspector.ExecutableKind.machO.ndbTarget, 9)
        XCTAssertEqual(FileInspector.ExecutableKind.pe.ndbTarget, 1)
        XCTAssertEqual(FileInspector.ExecutableKind.elf.ndbTarget, 6)
        XCTAssertNil(FileInspector.ExecutableKind.script.ndbTarget)
    }

    func testLaunchdPlistDetection() {
        XCTAssertTrue(FileInspector.isLaunchdPlist(URL(fileURLWithPath: "/Users/x/Library/LaunchAgents/com.evil.plist")))
        XCTAssertTrue(FileInspector.isLaunchdPlist(URL(fileURLWithPath: "/Library/LaunchDaemons/com.evil.PLIST")))
        XCTAssertFalse(FileInspector.isLaunchdPlist(URL(fileURLWithPath: "/Library/Preferences/com.apple.x.plist")))
        XCTAssertFalse(FileInspector.isLaunchdPlist(URL(fileURLWithPath: "/Library/LaunchAgents/readme.txt")))
    }

    // MARK: TCC mapping and merge

    func testTCCAuthValueMapping() {
        XCTAssertFalse(TCCPermissionsReader.granted(authValue: 0, legacySchema: false))   // denied
        XCTAssertFalse(TCCPermissionsReader.granted(authValue: 1, legacySchema: false))   // unknown / will prompt
        XCTAssertTrue(TCCPermissionsReader.granted(authValue: 2, legacySchema: false))    // allowed
        XCTAssertTrue(TCCPermissionsReader.granted(authValue: 3, legacySchema: false))    // limited is still access
        XCTAssertFalse(TCCPermissionsReader.granted(authValue: 7, legacySchema: false))
        XCTAssertFalse(TCCPermissionsReader.granted(authValue: 0, legacySchema: true))
        XCTAssertTrue(TCCPermissionsReader.granted(authValue: 1, legacySchema: true))
    }

    private func row(_ service: String, _ client: String, auth: Int, legacy: Bool = false, modified: Int64? = nil) -> TCCPermissionsReader.Row {
        TCCPermissionsReader.Row(service: service, client: client, clientType: 0,
                                 authValue: auth, lastModified: modified, legacySchema: legacy)
    }

    func testTCCMergePrefersUserRows() {
        let user = [
            row("kTCCServiceCamera", "com.example.a", auth: 2, modified: 200),
            row("kTCCServiceMicrophone", "com.example.a", auth: 0),
        ]
        let system = [
            row("kTCCServiceCamera", "com.example.a", auth: 0, modified: 100),          // shadowed by the user row
            row("kTCCServiceSystemPolicyAllFiles", "com.example.b", auth: 2),
            row("kTCCServiceMicrophone", "com.example.a", auth: 2, legacy: true),       // shadowed too
        ]
        let merged = TCCPermissionsReader.merge(user: user, system: system)
        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged[0], user[0])
        XCTAssertEqual(merged[1], user[1])
        XCTAssertEqual(merged[2], system[1])
        XCTAssertTrue(merged[0].granted)
        XCTAssertFalse(merged[1].granted)
        XCTAssertEqual(merged[0].lastModified, 200)
    }

    func testTCCMergeDedupesWithinOneSource() {
        let system = [
            row("kTCCServiceAccessibility", "com.example.a", auth: 2),
            row("kTCCServiceAccessibility", "com.example.a", auth: 0),
        ]
        let merged = TCCPermissionsReader.merge(user: [], system: system)
        XCTAssertEqual(merged.count, 1)
        XCTAssertTrue(merged[0].granted)
    }

    func testTCCReadErrorFlagsFullDiskAccess() {
        let url = TCCPermissionsReader.userDatabase
        XCTAssertTrue(TCCPermissionsReader.ReadError(kind: .cannotOpen, database: url, message: "authorization denied").needsFullDiskAccess)
        XCTAssertFalse(TCCPermissionsReader.ReadError(kind: .queryFailed, database: url, message: "no such table").needsFullDiskAccess)
    }

    // MARK: Code signature verdicts

    func testSignatureStatusClassification() {
        XCTAssertEqual(SecCodeSignatureVerifier.classify(errSecSuccess), true)
        XCTAssertEqual(SecCodeSignatureVerifier.classify(errSecCSUnsigned), false)
        XCTAssertEqual(SecCodeSignatureVerifier.classify(errSecCSSignatureFailed), false)
        XCTAssertEqual(SecCodeSignatureVerifier.classify(errSecCSBadResource), false)
        XCTAssertNil(SecCodeSignatureVerifier.classify(errSecCSStaticCodeNotFound))
        XCTAssertNil(SecCodeSignatureVerifier.classify(errSecCSObjectRequired))
        XCTAssertNil(SecCodeSignatureVerifier.classify(errSecIO))
    }

    func testSignatureCacheIsBounded() async {
        let cache = SignatureVerdictCache(capacity: 10)
        for index in 0..<10 {
            await cache.store(index.isMultiple(of: 2), for: "/p\(index)")
        }
        await cache.store(nil, for: "/unknown")   // 11th entry evicts the oldest tenth (1 entry)
        let count = await cache.count
        XCTAssertEqual(count, 10)
        let evicted = await cache.verdict(for: "/p0")
        XCTAssertNil(evicted)
        let kept = await cache.verdict(for: "/p1")
        XCTAssertEqual(kept?.value, false)
        let unknown = await cache.verdict(for: "/unknown")
        XCTAssertNotNil(unknown)
        XCTAssertNil(unknown?.value)   // cached "unknown" is a hit with a nil verdict
    }

    // MARK: Threat annotation

    func testThreatAnnotationAppendsDownloadSource() throws {
        let threat = Threat(path: URL(fileURLWithPath: "/Users/x/Downloads/eicar.com"),
                            name: "Eicar-Test-Signature",
                            kind: .signature,
                            severity: .critical,
                            detail: "Matches known malware hash",
                            sizeBytes: 68,
                            isDirectory: false)
        let quarantine = try XCTUnwrap(QuarantineAttribute.parse("0083;5f3e2b1c;Safari;"))
        let annotated = FileInspector.annotate(threat, with: quarantine)
        XCTAssertEqual(annotated.id, threat.id)
        XCTAssertEqual(annotated.detail, "Matches known malware hash • Downloaded from Safari")
        XCTAssertEqual(FileInspector.annotate(threat, with: nil), threat)
    }
}
