import Foundation
import Testing
import CleanerCore
import CleanerCoreTesting
@testable import ClutterModule

@Suite("Range reading")
struct RangeReadTests {
    @Test func mockFallsBackToSlicedContents() throws {
        let fs: MockFileSystem = ["/Users/test/f": .file("0123456789")]
        let url = URL(fileURLWithPath: "/Users/test/f")
        let any: any FileSystem = fs
        #expect(any is any RangeReadableFileSystem == false)
        #expect(try any.readRange(of: url, offset: 2, length: 3) == Data("234".utf8))
        #expect(try any.readRange(of: url, offset: 8, length: 10) == Data("89".utf8))
        #expect(try any.readRange(of: url, offset: 10, length: 1).isEmpty)
        #expect(try any.readRange(of: url, offset: 0, length: 0).isEmpty)
        #expect(SHA256.hexString(try any.sha256Digest(of: url))
                == SHA256.hexString(SHA256.hash(Data("0123456789".utf8))))
    }

    @Test func localFileSystemReadsRangesWithFileHandle() throws {
        let fixture = try FixtureBuilder(name: "clutter-range")
        defer { try? fixture.remove() }
        let data = pseudoRandomData(count: 100_000)
        let url = try fixture.file("blob.bin", contents: data)
        let fs: any FileSystem = LocalFileSystem()
        #expect(fs is any RangeReadableFileSystem)
        #expect(try fs.readRange(of: url, offset: 0, length: 4_096) == data.prefix(4_096))
        #expect(try fs.readRange(of: url, offset: 100_000 - 4_096, length: 4_096) == data.suffix(4_096))
        #expect(try fs.readRange(of: url, offset: 99_990, length: 4_096) == data.suffix(10))
        #expect(try fs.readRange(of: url, offset: 100_000, length: 16).isEmpty)
        #expect(try fs.sha256Digest(of: url, chunkSize: 7_777) == SHA256.hash(data))
        #expect(try fs.sha256Digest(of: url) == SHA256.hash(data))
        #expect(throws: FileSystemError.self) {
            try fs.readRange(of: fixture.url("missing"), offset: 0, length: 1)
        }
    }
}
