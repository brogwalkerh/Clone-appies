import Foundation
import Testing
import CleanerHashing

@Suite("MD5")
struct MD5Tests {
    private func hex(_ string: String) -> String {
        MD5.hexString(MD5.hash(Data(string.utf8)))
    }

    /// The RFC 1321 appendix A.5 test suite.
    @Test(arguments: [
        ("", "d41d8cd98f00b204e9800998ecf8427e"),
        ("a", "0cc175b9c0f1b6a831c399e269772661"),
        ("abc", "900150983cd24fb0d6963f7d28e17f72"),
        ("message digest", "f96b697d7cb7938d525a2f31aaf161d0"),
        ("abcdefghijklmnopqrstuvwxyz", "c3fcd3d76192e4007dfb496cca67e13b"),
        ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",
         "d174ab98d277d9f5a5611c2c9f419d9f"),
        ("12345678901234567890123456789012345678901234567890123456789012345678901234567890",
         "57edf4a22be3c955ac49da2e2107b67a"),
    ])
    func rfc1321Vectors(message: String, digest: String) {
        #expect(hex(message) == digest)
    }

    @Test func eicarTestFile() {
        let eicar = #"X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*"#
        #expect(hex(eicar) == "44d88612fea8a8f36de82e1278abb02f")
    }

    /// Boundary lengths around the 64-byte block and the 56-byte padding cut.
    @Test(arguments: [55, 56, 57, 63, 64, 65, 119, 120, 128])
    func paddingBoundaries(length: Int) {
        let data = Data(repeating: 0x61, count: length)
        var streaming = StreamingMD5()
        for byte in data { streaming.update(Data([byte])) }
        #expect(streaming.finalize() == MD5.hash(data))
    }

    @Test func streamingMatchesOneShotOnOneMegabyte() {
        let data = pseudoRandomData(count: 1 << 20)
        let oneShot = MD5.hash(data)
        #expect(oneShot.count == 16)

        var streaming = StreamingMD5()
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
        var streaming = StreamingMD5()
        streaming.update(Data())
        streaming.update(Data("abc".utf8))
        streaming.update(Data())
        #expect(MD5.hexString(streaming.finalize()) == hex("abc"))
    }

    @Test func hexStringIsLowercaseAndPadded() {
        #expect(MD5.hexString([0x00, 0x0a, 0xff]) == "000aff")
    }
}
