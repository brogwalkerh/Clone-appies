import Foundation
import Testing
@testable import CleanerCore
import CleanerCoreTesting

@Suite("Models")
struct ModelTests {
    @Test func riskLevelOrdering() {
        #expect(RiskLevel.safe < .caution)
        #expect(RiskLevel.caution < .risky)
        #expect([RiskLevel.risky, .safe, .caution].sorted() == [.safe, .caution, .risky])
    }

    @Test func findingCodableRoundTrip() throws {
        let f = Finding(path: URL(fileURLWithPath: "/tmp/x"), sizeBytes: 42,
                        category: FindingCategory(id: "a.b", displayName: "AB", module: .applications),
                        scannerID: "a.b", risk: .caution, detail: "d", modifiedAt: Date(timeIntervalSince1970: 1000),
                        isDirectory: true)
        let data = try JSONEncoder().encode(f)
        let decoded = try JSONDecoder().decode(Finding.self, from: data)
        #expect(decoded == f)
    }

    @Test func scanContextDefaultsHomeFromFileSystem() {
        let fs: MockFileSystem = ["/Users/test/file": .file(size: 1)]
        let context = ScanContext(fileSystem: fs)
        #expect(context.home.path == "/Users/test")
        #expect(!context.isOnBattery)
    }

    @Test func mockFileSystemBasics() throws {
        let fs: MockFileSystem = [
            "/Users/test/Library/Caches/app/a.bin": .file(size: 1_000),
            "/Users/test/notes.txt": .file("hello"),
            "/Users/test/link": .symlink(to: "/Users/test/Library"),
        ]
        #expect(fs.exists(URL(fileURLWithPath: "/Users/test/Library")))
        #expect(fs.exists(URL(fileURLWithPath: "/Users/test/Library/Caches")))
        #expect(!fs.exists(URL(fileURLWithPath: "/Users/test/nope")))
        #expect(try fs.attributes(of: URL(fileURLWithPath: "/Users/test/Library")).isDirectory)
        #expect(try fs.attributes(of: URL(fileURLWithPath: "/Users/test/link")).isSymlink)
        #expect(try fs.attributes(of: URL(fileURLWithPath: "/Users/test/Library/Caches/app/a.bin")).sizeBytes == 1_000)
        let children = try fs.children(of: URL(fileURLWithPath: "/Users/test")).map(\.lastPathComponent)
        #expect(children == ["Library", "link", "notes.txt"])
        #expect(String(decoding: try fs.contents(of: URL(fileURLWithPath: "/Users/test/notes.txt")), as: UTF8.self) == "hello")
        #expect(throws: FileSystemError.self) {
            try fs.children(of: URL(fileURLWithPath: "/Users/test/notes.txt"))
        }
    }

    @Test func localFileSystemAttributes() throws {
        let fixture = try FixtureBuilder()
        defer { try? fixture.remove() }
        let file = try fixture.file("f.bin", size: 1234, modified: Date(timeIntervalSince1970: 1_600_000_000))
        let dir = try fixture.directory("d")
        let link = try fixture.symlink("l", to: "d")
        let fs = LocalFileSystem()
        let fa = try fs.attributes(of: file)
        #expect(!fa.isDirectory && !fa.isSymlink)
        #expect(fa.sizeBytes >= 1234)
        #expect(fa.modifiedAt.map { abs($0.timeIntervalSince1970 - 1_600_000_000) < 2 } == true)
        let da = try fs.attributes(of: dir)
        #expect(da.isDirectory && da.sizeBytes == 0)
        let la = try fs.attributes(of: link)
        #expect(la.isSymlink && !la.isDirectory)
        #expect(try fs.children(of: fixture.root).map(\.lastPathComponent) == ["d", "f.bin", "l"])
        #expect(try fs.contents(of: file).count == 1234)
        #expect(throws: FileSystemError.self) { try fs.attributes(of: fixture.url("missing")) }
    }
}
