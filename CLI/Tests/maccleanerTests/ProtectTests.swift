import Foundation
import Testing
import CleanerCore
import CleanerCoreTesting
import CleanerHashing
import ProtectionModule
@testable import maccleaner

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Serves an in-memory feed for `SignatureUpdater` without touching the network.
final class StubFeedProtocol: URLProtocol {
    nonisolated(unsafe) static var responses: [String: (status: Int, body: Data)] = [:]
    nonisolated(unsafe) static var requested: [String] = []
    private static let lock = NSLock()

    static func reset(_ files: [String: Data]) {
        lock.withLock {
            responses = files.mapValues { (200, $0) }
            requested = []
        }
    }

    static func lookup(_ name: String) -> (status: Int, body: Data)? {
        lock.withLock {
            requested.append(name)
            return responses[name]
        }
    }

    static var requestedNames: [String] { lock.withLock { requested } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let name = url.lastPathComponent
        let (status, body) = Self.lookup(name) ?? (404, Data())
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("protect commands", .serialized)
struct ProtectTests {
    static let eicar = #"X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*"#

    private func makeHome() throws -> FixtureBuilder {
        let home = try FixtureBuilder(name: "cli-protect")
        try home.file("Downloads/eicar.com", contents: Data(Self.eicar.utf8))
        try home.file("Downloads/clean.txt", contents: Data("nothing to see here".utf8))
        try home.file("Documents/notes.md", contents: Data("# notes".utf8))
        return home
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    @Test("scan finds the EICAR file, prints grouped text and a JSON document")
    func scan() async throws {
        let home = try makeHome()
        defer { try? home.remove() }
        let database = try ProtectSignatures.loadDatabase(signaturesDirectory: nil)
        #expect(database.stats.hashSignatures > 0)
        let context = ScanContext(fileSystem: LocalFileSystem(), home: home.root)

        // Text mode: progress on stderr, grouped report on stdout.
        let out = BufferSink(), err = BufferSink()
        var options = ProtectScanOptions()
        options.scope = .quick
        let outcome = await ProtectScan.run(context: context, database: database, options: options,
                                            io: CommandIO(out: out, err: err))
        #expect(outcome.failure == nil)
        let threats = outcome.document.threats
        #expect(!threats.isEmpty)
        #expect(Set(threats.map(\.path.path)) == [home.url("Downloads/eicar.com").path])
        #expect(threats.contains { $0.name == "Eicar-Test-Signature" && $0.kind == .signature && $0.severity == .critical })
        #expect(threats.map(\.sizeBytes).allSatisfy { $0 == 68 })
        #expect(err.lines.first?.hasPrefix("[started]  protection.malware: scope quick") == true)
        #expect(err.lines.last?.hasPrefix("[finished] protection.malware: \(threats.count) threat") == true)
        #expect(out.text.hasPrefix("\(threats.count) threat\(threats.count == 1 ? "" : "s") found (scope quick, "))
        #expect(out.text.contains("\nCRITICAL (\(threats.count))\n"))
        #expect(out.text.contains("  [signature]  68 B  \(home.url("Downloads/eicar.com").path)"))
        #expect(out.text.contains("      Matches a known malware hash"))

        // JSON mode: no stderr, decodable, idempotent re-encoding.
        let jsonOut = BufferSink(), jsonErr = BufferSink()
        options.json = true
        let jsonOutcome = await ProtectScan.run(context: context, database: database, options: options,
                                                io: CommandIO(out: jsonOut, err: jsonErr))
        #expect(jsonErr.lines.isEmpty)
        #expect(jsonOut.lines.count == 1)
        let document = try ScanJSON.decode(ThreatScanDocument.self, from: Data(jsonOut.text.utf8))
        #expect(document.threats.map(\.name) == jsonOutcome.document.threats.map(\.name))
        #expect(document.scope == .quick)
        #expect(document.signatures == SignatureStats(database.stats))
        #expect(try ScanJSON.encode(document) == jsonOut.text)
    }

    @Test("a clean tree reports no threats")
    func clean() async throws {
        let home = try FixtureBuilder(name: "cli-protect-clean")
        defer { try? home.remove() }
        try home.file("Downloads/clean.txt", contents: Data("nothing to see here".utf8))
        let out = BufferSink()
        var options = ProtectScanOptions()
        options.scope = .quick
        let outcome = await ProtectScan.run(context: ScanContext(fileSystem: LocalFileSystem(), home: home.root),
                                            database: try ProtectSignatures.loadDatabase(signaturesDirectory: nil),
                                            options: options, io: CommandIO(out: out, err: BufferSink()))
        #expect(outcome.document.threats.isEmpty)
        #expect(out.text.hasPrefix("No threats found (scope quick, "))
    }

    @Test("quarantine moves the threat (once per path), then restore brings it back")
    func quarantineAndRestore() async throws {
        let home = try makeHome()
        defer { try? home.remove() }
        let quarantineRoot = try FixtureBuilder(name: "cli-quarantine")
        defer { try? quarantineRoot.remove() }
        let directory = quarantineRoot.url("q")
        let eicarURL = home.url("Downloads/eicar.com")

        var options = ProtectScanOptions()
        options.scope = .quick
        options.json = true
        let scanOut = BufferSink()
        _ = await ProtectScan.run(context: ScanContext(fileSystem: LocalFileSystem(), home: home.root),
                                  database: try ProtectSignatures.loadDatabase(signaturesDirectory: nil),
                                  options: options, io: CommandIO(out: scanOut, err: BufferSink()))
        let document = try ScanJSON.decode(ThreatScanDocument.self, from: Data(scanOut.text.utf8))
        #expect(document.threats.count >= 1)

        // Declined prompt: nothing moves.
        let declinedOut = BufferSink()
        let declined = await ProtectQuarantineRunner.run(threats: document.threats,
                                                         quarantine: ThreatQuarantine(directory: directory),
                                                         directory: directory, options: ProtectQuarantineOptions(),
                                                         confirm: { false }, io: CommandIO(out: declinedOut, err: BufferSink()))
        #expect(declined.aborted)
        #expect(declined.manifest == nil)
        #expect(declined.selected.count == 1, "several threats on one path quarantine once")
        #expect(declinedOut.lines.first == "Would quarantine 1 item (68 B) into \(directory.path):")
        #expect(declinedOut.lines.last == "Aborted.")
        #expect(exists(eicarURL))

        // --yes: moved, chmod 000, manifest on disk.
        var yes = ProtectQuarantineOptions()
        yes.assumeYes = true
        let out = BufferSink()
        let outcome = await ProtectQuarantineRunner.run(threats: document.threats,
                                                        quarantine: ThreatQuarantine(directory: directory),
                                                        directory: directory, options: yes,
                                                        confirm: { Issue.record("--yes must not prompt"); return false },
                                                        io: CommandIO(out: out, err: BufferSink()))
        let manifest = try #require(outcome.manifest)
        let manifestURL = try #require(outcome.manifestURL)
        #expect(manifest.records.count == 1)
        #expect(manifest.records.first?.succeeded == true)
        #expect(!exists(eicarURL))
        #expect(exists(manifestURL))
        #expect(manifestURL.path == directory.appendingPathComponent(manifest.id.uuidString).appendingPathComponent("manifest.json").path)
        let stored = try #require(manifest.records.first?.storedAt)
        #expect(exists(stored))
        #expect(out.text.contains("Quarantined 1 of 1 item."))
        #expect(out.text.contains("Restore with: maccleaner protect restore --manifest \(manifestURL.path) --dir \(directory.path)"))

        // restore --manifest: back in place with the original bytes.
        let loaded = try ScanJSON.decode(QuarantineManifest.self, from: manifestURL)
        #expect(loaded.id == manifest.id)
        let restoreOut = BufferSink()
        let restored = await ProtectRestoreRunner.run(manifest: loaded, quarantine: ThreatQuarantine(directory: directory),
                                                      io: CommandIO(out: restoreOut, err: BufferSink()))
        #expect(restored.restored == 1)
        #expect(restored.failed == 0)
        #expect(restoreOut.lines == ["Restored 1 item, 0 failed."])
        #expect(exists(eicarURL))
        #expect(try Data(contentsOf: eicarURL) == Data(Self.eicar.utf8))
        #expect(!exists(stored))
    }

    @Test("update downloads a feed through a stubbed session and sigs reports the merged totals")
    func updateAndSigs() async throws {
        let dest = try FixtureBuilder(name: "cli-sigs")
        defer { try? dest.remove() }
        let hdb = Data("0123456789abcdef0123456789abcdef:1234:Osx.Trojan.Example-1\nfedcba9876543210fedcba9876543210:*:Osx.Adware.Example-2\n".utf8)
        let ndb = Data("Osx.Dldr.Example-3:0:*:4d4143434c45414e45522d55504441544554455354\n".utf8)
        let ign2 = Data("Eicar-Test-Signature-Pattern\n".utf8)
        func sha256(_ data: Data) -> String { SHA256.hexString(SHA256.hash(data)) }
        let manifest = """
        {"version": "2026-10-13", "files": [
          {"name": "mac.hdb", "sha256": "\(sha256(hdb))", "bytes": \(hdb.count)},
          {"name": "mac.ndb", "sha256": "\(sha256(ndb))", "bytes": \(ndb.count)},
          {"name": "allow.ign2", "sha256": "\(sha256(ign2))", "bytes": \(ign2.count)}
        ]}
        """
        StubFeedProtocol.reset(["manifest.json": Data(manifest.utf8), "mac.hdb": hdb, "mac.ndb": ndb, "allow.ign2": ign2])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubFeedProtocol.self]
        let session = URLSession(configuration: configuration)
        let updater = SignatureUpdater(baseURL: URL(string: "https://feed.example.test/signatures/")!,
                                       session: session, destination: dest.url("db"))

        let out = BufferSink(), err = BufferSink()
        let result = try await ProtectUpdateRunner.run(updater: updater, io: CommandIO(out: out, err: err))
        #expect(result.version == "2026-10-13")
        #expect(result.filesUpdated == 3)
        #expect(result.bytes == Int64(hdb.count + ndb.count + ign2.count))
        #expect(updater.currentVersion() == "2026-10-13")
        #expect(exists(dest.url("db/mac.hdb")))
        #expect(Set(StubFeedProtocol.requestedNames) == ["manifest.json", "mac.hdb", "mac.ndb", "allow.ign2"])
        #expect(out.lines == ["Signatures updated to version 2026-10-13: 3 files, \(ByteFormatter.string(result.bytes)) downloaded into \(dest.url("db").path)"])
        #expect(err.lines.first == "[started]  signature update from https://feed.example.test/signatures/ (current: none)")

        // A second run downloads nothing.
        let again = try await ProtectUpdateRunner.run(updater: updater, io: CommandIO(out: BufferSink(), err: BufferSink()))
        #expect(again.filesUpdated == 0)

        // sigs: bundled starter plus the downloaded directory.
        let bundled = SignatureStats(try ProtectSignatures.loadDatabase(signaturesDirectory: nil).stats)
        let merged = try ProtectSignatures.loadDatabase(signaturesDirectory: dest.url("db"))
        let stats = SignatureStats(merged.stats)
        #expect(stats.hashSignatures == bundled.hashSignatures + 2)
        #expect(stats.patternSignatures == bundled.patternSignatures + 1)
        #expect(stats.allowlisted == bundled.allowlisted + 1)
        #expect(merged.isAllowlisted("Eicar-Test-Signature-Pattern"))

        let textOut = BufferSink()
        try ProtectSigs.run(database: merged, directory: dest.url("db"), json: false, io: CommandIO(out: textOut, err: BufferSink()))
        #expect(textOut.text.hasPrefix("Signature sources: bundled starter set + \(dest.url("db").path)\n"))
        #expect(textOut.text.contains("\n  Hash signatures:    \(stats.hashSignatures)\n"))
        let jsonOut = BufferSink()
        try ProtectSigs.run(database: merged, directory: nil, json: true, io: CommandIO(out: jsonOut, err: BufferSink()))
        #expect(try ScanJSON.decode(SignatureStats.self, from: Data(jsonOut.text.utf8)) == stats)
    }

    @Test("a corrupt feed is rejected and leaves no files behind")
    func updateRejectsBadDigest() async throws {
        let dest = try FixtureBuilder(name: "cli-sigs-bad")
        defer { try? dest.remove() }
        let hdb = Data("0123456789abcdef0123456789abcdef:1234:Osx.Trojan.Example-1\n".utf8)
        let manifest = #"{"version": "2026-10-13", "files": [{"name": "mac.hdb", "sha256": "00", "bytes": 0}]}"#
        StubFeedProtocol.reset(["manifest.json": Data(manifest.utf8), "mac.hdb": hdb])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubFeedProtocol.self]
        let updater = SignatureUpdater(baseURL: URL(string: "https://feed.example.test/")!,
                                       session: URLSession(configuration: configuration), destination: dest.url("db"))
        let err = BufferSink()
        await #expect(throws: SignatureUpdateError.self) {
            _ = try await ProtectUpdateRunner.run(updater: updater, io: CommandIO(out: BufferSink(), err: err))
        }
        #expect(err.lines.last?.hasPrefix("[failed]   signature update: ") == true)
        #expect(!exists(dest.url("db/mac.hdb")))
        #expect(updater.currentVersion() == nil)
    }

    @Test("the registry exposes the privacy scanners under the protection module")
    func privacyScannersRegistered() throws {
        let registry = ScannerRegistry.builtIn()
        let protection = try registry.filtered(module: .protection)
        #expect(!protection.isEmpty)
        #expect(protection.contains { $0.id == "privacy.safariHistory" })
        #expect(protection.allSatisfy { $0.module == .protection })
    }
}
