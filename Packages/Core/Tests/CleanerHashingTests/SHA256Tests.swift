import Foundation
import Testing
import CleanerHashing

@Suite("SHA256")
struct SHA256Tests {
    private func hex(_ string: String) -> String {
        SHA256.hexString(SHA256.hash(Data(string.utf8)))
    }

    @Test func emptyMessage() {
        #expect(hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func abc() {
        #expect(hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func twoBlockMessage() {
        #expect(hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
                == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    @Test func millionAs() {
        let data = Data(repeating: UInt8(ascii: "a"), count: 1_000_000)
        #expect(SHA256.hexString(SHA256.hash(data))
                == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    /// Boundary lengths around the 64-byte block and the 56-byte padding cut.
    @Test(arguments: [55, 56, 57, 63, 64, 65, 119, 120, 128])
    func paddingBoundaries(length: Int) {
        let data = Data(repeating: 0x61, count: length)
        var streaming = StreamingSHA256()
        for byte in data { streaming.update(Data([byte])) }
        #expect(streaming.finalize() == SHA256.hash(data))
    }

    @Test func streamingMatchesOneShotOnOneMegabyte() {
        let data = pseudoRandomData(count: 1 << 20)
        let oneShot = SHA256.hash(data)
        #expect(SHA256.hexString(oneShot) == "c7f83242f7967cc3ff4cacc879c31c6fde4596b95b1820a9c061e83df73d0d6f")

        var streaming = StreamingSHA256()
        let chunkSizes = [1, 3, 7, 61, 63, 65, 1_000, 4_095, 4_097, 65_537, 99_991]
        var offset = 0
        var i = 0
        while offset < data.count {
            let size = min(chunkSizes[i % chunkSizes.count], data.count - offset)
            streaming.update(data.subdata(in: offset..<(offset + size)))
            offset += size
            i += 1
        }
        #expect(streaming.finalize() == oneShot)
    }

    @Test func updateWithEmptyDataIsNoOp() {
        var streaming = StreamingSHA256()
        streaming.update(Data())
        streaming.update(Data("abc".utf8))
        streaming.update(Data())
        #expect(SHA256.hexString(streaming.finalize()) == hex("abc"))
    }

    @Test func hexStringIsLowercaseAndPadded() {
        #expect(SHA256.hexString([0x00, 0x0a, 0xff]) == "000aff")
        #expect(SHA256.hash(Data()).count == 32)
    }
}
