import Foundation
import Testing
import CleanerCore
import CleanerCoreTesting
@testable import ClutterModule

@Suite("FNV-1a 64 prefilter")
struct FNV1a64Tests {
    @Test func knownVectors() {
        #expect(FNV1a64.hash(Data()) == 0xcbf2_9ce4_8422_2325)
        #expect(FNV1a64.hash(Data("a".utf8)) == 0xaf63_dc4c_8601_ec8c)
        #expect(FNV1a64.hash(Data("foobar".utf8)) == 0x8594_4171_f739_67e8)
    }

    @Test func incrementalUpdatesMatchOneShot() {
        var hasher = FNV1a64()
        hasher.update(Data("foo".utf8))
        hasher.update(Data("bar".utf8))
        #expect(hasher.value == FNV1a64.hash(Data("foobar".utf8)))
    }

    @Test func headTailPrefilterIgnoresTheMiddle() throws {
        let size = 3 * DuplicatesScanner.sampleLength
        let a = paddedData(count: size, edge: DuplicatesScanner.sampleLength, fill: 1)
        let b = paddedData(count: size, edge: DuplicatesScanner.sampleLength, fill: 2)
        var tailDiffers = a
        tailDiffers[size - 1] = 9
        let fs: MockFileSystem = [
            "/Users/test/a": .data(a),
            "/Users/test/b": .data(b),
            "/Users/test/c": .data(tailDiffers),
        ]
        let hash = { (name: String) throws -> UInt64 in
            try DuplicatesScanner.prefilterHash(of: URL(fileURLWithPath: "/Users/test/\(name)"),
                                                size: Int64(size), fileSystem: fs)
        }
        #expect(try hash("a") == hash("b"))
        #expect(try hash("a") != hash("c"))
    }

    @Test func smallFilesAreHashedWhole() throws {
        let fs: MockFileSystem = [
            "/Users/test/a": .file("hello"),
            "/Users/test/b": .file("hallo"),
        ]
        let a = try DuplicatesScanner.prefilterHash(of: URL(fileURLWithPath: "/Users/test/a"), size: 5, fileSystem: fs)
        let b = try DuplicatesScanner.prefilterHash(of: URL(fileURLWithPath: "/Users/test/b"), size: 5, fileSystem: fs)
        #expect(a != b)
        #expect(a == FNV1a64.hash(Data("hello".utf8)))
    }
}
