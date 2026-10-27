import Foundation
import Testing
import CleanerCore
import CleanerCoreTesting
import CleanerHashing
@testable import ProtectionModule
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Serves canned responses keyed by absolute URL; records every request.
final class FeedStub: URLProtocol {
    nonisolated(unsafe) private static var responses: [String: (status: Int, body: Data)] = [:]
    nonisolated(unsafe) private static var requests: [String] = []
    private static let lock = NSLock()

    static func register(_ url: URL, status: Int = 200, body: Data) {
        lock.withLock { responses[url.absoluteString] = (status, body) }
    }

    static func requested(under base: URL) -> [String] {
        lock.withLock { requests.filter { $0.hasPrefix(base.absoluteString) }.map { String($0.dropFirst(base.absoluteString.count)) } }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let key = url.absoluteString
        let response = Self.lock.withLock { () -> (status: Int, body: Data) in
            Self.requests.append(key)
            return Self.responses[key] ?? (404, Data())
        }
        let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("SignatureUpdater")
struct SignatureUpdaterTests {
    let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FeedStub.self]
        return URLSession(configuration: configuration)
    }()

    let hdb = Data("\(eicarMD5):68:Eicar-Test-Signature\n".utf8)
    let ndb = Data("Eicar-Test-Signature-Pattern:0:*:\(hex(eicar))\n".utf8)

    private func sha(_ data: Data) -> String { SHA256.hexString(SHA256.hash(data)) }

    private func feed(version: String = "2026-10-13", files: [(String, Data, String?)]) -> URL {
        let base = URL(string: "https://feed-\(UUID().uuidString.lowercased()).invalid/signatures")!
        let entries = files.map { name, data, digest in
            "{\"name\": \"\(name)\", \"sha256\": \"\(digest ?? sha(data))\", \"bytes\": \(data.count)}"
        }
        let manifest = "{\"version\": \"\(version)\", \"files\": [\(entries.joined(separator: ","))]}"
        FeedStub.register(base.appendingPathComponent("manifest.json"), body: Data(manifest.utf8))
        for (name, data, _) in files {
            FeedStub.register(base.appendingPathComponent(name), body: data)
        }
        return base
    }

    private func updater(_ base: URL, _ fixture: FixtureBuilder) -> SignatureUpdater {
        SignatureUpdater(baseURL: base, session: session, destination: fixture.url("signatures"))
    }

    @Test func freshInstallDownloadsEverythingAndWritesVersion() async throws {
        let fixture = try FixtureBuilder(name: "updater-fresh")
        defer { try? fixture.remove() }
        let base = feed(files: [("mac.hdb", hdb, nil), ("mac.ndb", ndb, nil)])
        let updater = updater(base, fixture)
        #expect(updater.currentVersion() == nil)

        let result = try await updater.update()
        #expect(result == SignatureUpdateResult(version: "2026-10-13", filesUpdated: 2, bytes: Int64(hdb.count + ndb.count)))
        #expect(updater.currentVersion() == "2026-10-13")
        #expect(try Data(contentsOf: fixture.url("signatures/mac.hdb")) == hdb)
        #expect(try Data(contentsOf: fixture.url("signatures/mac.ndb")) == ndb)
        #expect(FeedStub.requested(under: base) == ["/manifest.json", "/mac.hdb", "/mac.ndb"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.url("signatures").path).sorted()
                == ["VERSION", "mac.hdb", "mac.ndb"])

        var db = SignatureDatabase()
        try db.load(contentsOf: fixture.url("signatures"), fileSystem: LocalFileSystem())
        #expect(db.stats.hashSignatures == 1 && db.stats.patternSignatures == 1)
    }

    @Test func unchangedFilesAreNotDownloaded() async throws {
        let fixture = try FixtureBuilder(name: "updater-unchanged")
        defer { try? fixture.remove() }
        try fixture.file("signatures/mac.hdb", contents: hdb)
        let base = feed(version: "v2", files: [("mac.hdb", hdb, nil), ("mac.ndb", ndb, nil)])
        let result = try await updater(base, fixture).update()
        #expect(result.filesUpdated == 1)
        #expect(result.bytes == Int64(ndb.count))
        #expect(FeedStub.requested(under: base) == ["/manifest.json", "/mac.ndb"])
        #expect(updater(base, fixture).currentVersion() == "v2")

        let again = try await updater(base, fixture).update()
        #expect(again.filesUpdated == 0)
        #expect(again.version == "v2")
    }

    @Test func badDigestRejectsTheWholeUpdate() async throws {
        let fixture = try FixtureBuilder(name: "updater-digest")
        defer { try? fixture.remove() }
        try fixture.file("signatures/mac.hdb", contents: Data("old".utf8))
        let base = feed(files: [("mac.hdb", hdb, nil), ("mac.ndb", ndb, String(repeating: "0", count: 64))])
        await #expect(throws: SignatureUpdateError.digestMismatch(name: "mac.ndb", expected: String(repeating: "0", count: 64), actual: sha(ndb))) {
            try await updater(base, fixture).update()
        }
        // Nothing was installed, not even the file that verified, and no staging dir is left behind.
        #expect(try Data(contentsOf: fixture.url("signatures/mac.hdb")) == Data("old".utf8))
        #expect(!FileManager.default.fileExists(atPath: fixture.url("signatures/mac.ndb").path))
        #expect(updater(base, fixture).currentVersion() == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.url("signatures").path) == ["mac.hdb"])
    }

    @Test func sizeMismatchIsRejected() async throws {
        let fixture = try FixtureBuilder(name: "updater-size")
        defer { try? fixture.remove() }
        let base = URL(string: "https://feed-\(UUID().uuidString.lowercased()).invalid")!
        let manifest = "{\"version\": \"v\", \"files\": [{\"name\": \"a.hdb\", \"sha256\": \"\(sha(hdb))\", \"bytes\": 1}]}"
        FeedStub.register(base.appendingPathComponent("manifest.json"), body: Data(manifest.utf8))
        FeedStub.register(base.appendingPathComponent("a.hdb"), body: hdb)
        await #expect(throws: SignatureUpdateError.sizeMismatch(name: "a.hdb", expected: 1, actual: Int64(hdb.count))) {
            try await updater(base, fixture).update()
        }
    }

    @Test func atomicReplaceOfExistingFile() async throws {
        let fixture = try FixtureBuilder(name: "updater-replace")
        defer { try? fixture.remove() }
        try fixture.file("signatures/mac.hdb", contents: Data("stale".utf8))
        try fixture.file("signatures/VERSION", contents: Data("v1".utf8))
        let base = feed(version: "v2", files: [("mac.hdb", hdb, nil)])
        let result = try await updater(base, fixture).update()
        #expect(result.filesUpdated == 1)
        #expect(try Data(contentsOf: fixture.url("signatures/mac.hdb")) == hdb)
        #expect(updater(base, fixture).currentVersion() == "v2")
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.url("signatures").path).sorted() == ["VERSION", "mac.hdb"])
    }

    @Test(arguments: ["../evil.hdb", "sub/x.hdb", "notes.txt", ".hidden.hdb", "VERSION", ""])
    func unsafeFileNamesAreRejected(name: String) async throws {
        let fixture = try FixtureBuilder(name: "updater-names")
        defer { try? fixture.remove() }
        let base = feed(files: [(name, hdb, nil)])
        await #expect(throws: SignatureUpdateError.invalidFileName(name)) {
            try await updater(base, fixture).update()
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.url("signatures/VERSION").path))
    }

    @Test func manifestNameItselfIsNotAnAllowedFile() {
        #expect(throws: SignatureUpdateError.invalidFileName("manifest.json")) {
            try SignatureUpdater.validate(name: "manifest.json")
        }
        #expect(throws: Never.self) { try SignatureUpdater.validate(name: "mac.ign2") }
    }

    @Test func httpErrorsAndBadManifestsThrow() async throws {
        let fixture = try FixtureBuilder(name: "updater-errors")
        defer { try? fixture.remove() }
        let missing = URL(string: "https://feed-\(UUID().uuidString.lowercased()).invalid")!
        await #expect(throws: SignatureUpdateError.badResponse(missing.appendingPathComponent("manifest.json"), statusCode: 404)) {
            try await updater(missing, fixture).update()
        }
        let garbage = URL(string: "https://feed-\(UUID().uuidString.lowercased()).invalid")!
        FeedStub.register(garbage.appendingPathComponent("manifest.json"), body: Data("not json".utf8))
        await #expect(throws: SignatureUpdateError.self) {
            try await updater(garbage, fixture).update()
        }
        let fileMissing = URL(string: "https://feed-\(UUID().uuidString.lowercased()).invalid")!
        FeedStub.register(fileMissing.appendingPathComponent("manifest.json"),
                          body: Data("{\"version\": \"v\", \"files\": [{\"name\": \"a.hdb\", \"sha256\": \"\(sha(hdb))\", \"bytes\": 0}]}".utf8))
        await #expect(throws: SignatureUpdateError.badResponse(fileMissing.appendingPathComponent("a.hdb"), statusCode: 404)) {
            try await updater(fileMissing, fixture).update()
        }
    }
}
