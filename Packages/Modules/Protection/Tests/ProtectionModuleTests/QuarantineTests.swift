import Foundation
import Testing
import CleanerCore
import CleanerCoreTesting
@testable import ProtectionModule

@Suite("ThreatQuarantine", .serialized)
struct QuarantineTests {
    private func threat(_ url: URL, isDirectory: Bool = false) -> Threat {
        Threat(path: url, name: "Eicar-Test-Signature", kind: .signature, severity: .critical,
               detail: "test", sizeBytes: 68, isDirectory: isDirectory)
    }

    private func permissions(_ url: URL) -> Int16? {
        ThreatQuarantine.permissions(of: url)
    }

    @Test func roundTripRestoresFilesDirectoriesAndPermissions() async throws {
        let fixture = try FixtureBuilder(name: "quarantine")
        defer { try? fixture.remove() }
        let script = try fixture.file("home/evil.sh", contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let plain = try fixture.file("home/evil.txt", contents: Data(eicar.utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plain.path)
        let bundle = try fixture.directory("home/Evil.app")
        try fixture.file("home/Evil.app/Contents/MacOS/evil", contents: Data(eicar.utf8))
        let quarantineDirectory = fixture.url("quarantine")
        let quarantine = ThreatQuarantine(directory: quarantineDirectory)

        let manifest = await quarantine.quarantine([threat(script), threat(plain), threat(bundle, isDirectory: true)])
        #expect(manifest.records.count == 3)
        #expect(manifest.records.allSatisfy { $0.succeeded })
        #expect(manifest.records.map(\.originalPermissions) == [0o755, 0o600, 0o755])
        for (record, original) in zip(manifest.records, [script, plain, bundle]) {
            let stored = try #require(record.storedAt)
            #expect(!FileManager.default.fileExists(atPath: original.path))
            #expect(FileManager.default.fileExists(atPath: stored.path))
            #expect(stored.path == quarantineDirectory.appendingPathComponent(
                "\(manifest.id.uuidString)/\(record.threat.id.uuidString)/\(original.lastPathComponent)").path)
            #expect(permissions(stored) == 0)
        }
        let manifestFile = quarantineDirectory.appendingPathComponent("\(manifest.id.uuidString)/manifest.json")
        #expect(FileManager.default.fileExists(atPath: manifestFile.path))
        #expect(try await quarantine.list() == [manifest])

        let restored = await quarantine.restore(manifest)
        #expect(restored.allSatisfy { $0.succeeded && $0.storedAt == nil })
        #expect(FileManager.default.fileExists(atPath: script.path))
        #expect(FileManager.default.fileExists(atPath: plain.path))
        #expect(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Contents/MacOS/evil").path))
        #expect(permissions(script) == 0o755)
        #expect(permissions(plain) == 0o644)
        #expect(permissions(bundle) == 0o755)
        #expect(try String(contentsOf: plain, encoding: .utf8) == eicar)
        #expect(try await quarantine.list().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: quarantineDirectory.appendingPathComponent(manifest.id.uuidString).path))
    }

    @Test func missingSourceAndProtectedPathsAreRecordedAsFailures() async throws {
        let fixture = try FixtureBuilder(name: "quarantine-missing")
        defer { try? fixture.remove() }
        let quarantine = ThreatQuarantine(directory: fixture.url("q"))
        let manifest = await quarantine.quarantine([threat(fixture.url("nope")), threat(URL(fileURLWithPath: "/usr/bin/true"))])
        #expect(manifest.records.map(\.succeeded) == [false, false])
        #expect(manifest.records.allSatisfy { $0.error != nil && $0.storedAt == nil })
        #expect(manifest.records[1].error == "Protected path")
        #expect(try await quarantine.list().count == 1)
        #expect(try await quarantine.purge(olderThan: 0) == 1)
    }

    @Test func restoreRefusesToOverwriteAndKeepsManifest() async throws {
        let fixture = try FixtureBuilder(name: "quarantine-overwrite")
        defer { try? fixture.remove() }
        let file = try fixture.file("home/a.bin", contents: Data(eicar.utf8))
        let quarantine = ThreatQuarantine(directory: fixture.url("q"))
        let manifest = await quarantine.quarantine([threat(file)])
        try fixture.file("home/a.bin", contents: Data("replacement".utf8))

        let results = await quarantine.restore(manifest)
        #expect(results.count == 1)
        #expect(results[0].succeeded == false)
        #expect(results[0].storedAt == manifest.records[0].storedAt)
        #expect(try await quarantine.list().count == 1)
        #expect(try String(contentsOf: file, encoding: .utf8) == "replacement")
        #expect(try await quarantine.purge(olderThan: 0) == 1)
        #expect(try await quarantine.list().isEmpty)
    }

    @Test func failedRestoreCanBeRetried() async throws {
        let fixture = try FixtureBuilder(name: "quarantine-retry")
        defer { try? fixture.remove() }
        let file = try fixture.file("home/a.bin", contents: Data(eicar.utf8))
        let quarantine = ThreatQuarantine(directory: fixture.url("q"))
        _ = await quarantine.quarantine([threat(file)])
        try fixture.file("home/a.bin", contents: Data("in the way".utf8))
        let first = await quarantine.restore(try #require(try await quarantine.list().first))
        #expect(first.map(\.succeeded) == [false])

        try FileManager.default.removeItem(at: file)
        let onDisk = try #require(try await quarantine.list().first)
        let second = await quarantine.restore(onDisk)
        #expect(second.map(\.succeeded) == [true])
        #expect(second.allSatisfy { $0.storedAt == nil })
        #expect(try String(contentsOf: file, encoding: .utf8) == eicar)
        #expect(try await quarantine.list().isEmpty)
    }

    @Test func failedRestoreKeepsStoredItemLocked() async throws {
        let fixture = try FixtureBuilder(name: "quarantine-relock")
        defer { try? fixture.remove() }
        let file = try fixture.file("home/a.bin", contents: Data(eicar.utf8))
        let quarantine = ThreatQuarantine(directory: fixture.url("q"))
        let manifest = await quarantine.quarantine([threat(file)])
        try fixture.file("home/a.bin", contents: Data("in the way".utf8))
        let stored = try #require(manifest.records[0].storedAt)
        _ = await quarantine.restore(manifest)
        #expect(permissions(stored) == 0)

        // The move itself fails (after the item was unlocked for it): it is
        // locked again. Root ignores the read-only directory, so non-root only.
        if geteuid() != 0 {
            try FileManager.default.removeItem(at: file)
            let home = fixture.url("home")
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: home.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.path) }
            let results = await quarantine.restore(manifest)
            #expect(results.map(\.succeeded) == [false])
            #expect(permissions(stored) == 0)
        }
        #expect(try await quarantine.purge(olderThan: 0) == 1)
    }

    /// A restore whose move has to copy (quarantine on another volume) must
    /// make the item readable first. Needs a non-root user, since root reads
    /// mode-000 files anyway, and a second file system (Linux: /dev/shm).
    @Test func crossVolumeRestoreReadsTheLockedItem() async throws {
        let shm = URL(fileURLWithPath: "/dev/shm", isDirectory: true)
        let fm = FileManager.default
        guard geteuid() != 0, fm.isWritableFile(atPath: shm.path) else { return }
        let fixture = try FixtureBuilder(name: "quarantine-xdev")
        defer { try? fixture.remove() }
        let other = FixtureBuilder(root: shm.appendingPathComponent("quarantine-xdev-\(UUID().uuidString)"))
        try fm.createDirectory(at: other.root, withIntermediateDirectories: true)
        defer { try? other.remove() }
        let device = { (url: URL) in (try? fm.attributesOfItem(atPath: url.path))?[.systemNumber] as? NSNumber }
        guard let a = device(fixture.root), let b = device(other.root), a != b else { return }

        let file = try fixture.file("home/a.bin", contents: Data(eicar.utf8))
        let quarantine = ThreatQuarantine(directory: other.url("q"))
        let manifest = await quarantine.quarantine([threat(file)])
        #expect(manifest.records.map(\.succeeded) == [true])
        let restored = await quarantine.restore(manifest)
        #expect(restored.map(\.succeeded) == [true], "\(restored.compactMap(\.error))")
        #expect(try String(contentsOf: file, encoding: .utf8) == eicar)
    }

    @Test func purgeHonoursAge() async throws {
        let fixture = try FixtureBuilder(name: "quarantine-purge")
        defer { try? fixture.remove() }
        let file = try fixture.file("home/a.bin", contents: Data(eicar.utf8))
        let quarantine = ThreatQuarantine(directory: fixture.url("q"))
        let manifest = await quarantine.quarantine([threat(file)])
        #expect(try await quarantine.purge(olderThan: 3_600) == 0)
        #expect(try await quarantine.list() == [manifest])
        #expect(try await quarantine.purge(olderThan: 0) == 1)
        #expect(try await quarantine.list().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: manifest.records[0].storedAt!.path))
    }

    @Test func listOnMissingDirectoryIsEmpty() async throws {
        let quarantine = ThreatQuarantine(directory: URL(fileURLWithPath: "/nonexistent/quarantine-\(UUID().uuidString)"))
        #expect(try await quarantine.list().isEmpty)
        #expect(try await quarantine.purge(olderThan: 0) == 0)
    }

    @Test func recordDecodesWithoutPermissionsField() throws {
        let threat = threat(URL(fileURLWithPath: "/tmp/x"))
        let json = """
        {"threat": \(String(decoding: try JSONEncoder().encode(threat), as: UTF8.self)), "storedAt": null, "succeeded": false, "error": "e"}
        """
        let record = try JSONDecoder().decode(QuarantineRecord.self, from: Data(json.utf8))
        #expect(record.originalPermissions == 0o644)
        #expect(record.restoredPermissions == 0o644)
        #expect(QuarantineRecord(threat: threat, storedAt: nil, succeeded: true, error: nil, originalPermissions: 0o711).restoredPermissions == 0o755)
        let directory = Threat(path: URL(fileURLWithPath: "/tmp/d"), name: "n", kind: .heuristic, severity: .low,
                               detail: "d", sizeBytes: 0, isDirectory: true)
        #expect(QuarantineRecord(threat: directory, storedAt: nil, succeeded: true, error: nil, originalPermissions: 0o600).restoredPermissions == 0o755)
        let roundTrip = try JSONDecoder().decode(QuarantineRecord.self, from: try JSONEncoder().encode(record))
        #expect(roundTrip == record)
    }
}
