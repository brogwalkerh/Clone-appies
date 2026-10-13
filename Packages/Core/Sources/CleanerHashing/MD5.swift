import Foundation

/// MD5 (RFC 1321), pure Swift, one-shot convenience API.
///
/// MD5 is not collision resistant and is used here only because ClamAV's
/// `.hdb` hash lists are keyed by it. Never use it for integrity checks of
/// downloaded data; use `SHA256` for that.
public struct MD5: Sendable {
    /// Digest of `data` as 16 bytes.
    public static func hash(_ data: Data) -> [UInt8] {
        var hasher = StreamingMD5()
        hasher.update(data)
        return hasher.finalize()
    }

    /// Lower-case hexadecimal rendering of a digest.
    public static func hexString(_ digest: [UInt8]) -> String {
        SHA256.hexString(digest)
    }
}

/// Incremental MD5. Feed any number of `update` calls, then `finalize`
/// once; the hasher must not be reused afterwards.
public struct StreamingMD5: Sendable {
    private static let initialState: [UInt32] = [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476]

    /// Per-round left-rotation amounts.
    private static let shifts: [UInt32] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ]

    /// floor(abs(sin(i + 1)) * 2^32) for i in 0..<64.
    private static let constants: [UInt32] = [
        0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
        0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
        0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
        0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
        0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
        0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
        0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
        0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
    ]

    private static let blockSize = 64

    private var state: [UInt32] = StreamingMD5.initialState
    /// Bytes not yet forming a full block (always fewer than `blockSize`).
    private var pending: [UInt8] = []
    /// Total number of message bytes seen so far.
    private var messageLength: UInt64 = 0

    public init() {
        pending.reserveCapacity(Self.blockSize)
    }

    public mutating func update(_ data: Data) {
        if data.isEmpty { return }
        data.withUnsafeBytes { raw in
            update(bytes: raw)
        }
    }

    /// Consumes `digest` after padding the message. The hasher is spent afterwards.
    public mutating func finalize() -> [UInt8] {
        let bitLength = messageLength &* 8
        var padding: [UInt8] = [0x80]
        let remainder = (Int(messageLength % UInt64(Self.blockSize)) + 1) % Self.blockSize
        let zeros = remainder <= 56 ? 56 - remainder : Self.blockSize + 56 - remainder
        padding.append(contentsOf: repeatElement(0, count: zeros))
        // MD5 stores the length little-endian, unlike SHA-2.
        for shift in stride(from: 0, through: 56, by: 8) {
            padding.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }
        padding.withUnsafeBytes { raw in
            update(bytes: raw)
        }
        var digest: [UInt8] = []
        digest.reserveCapacity(16)
        for word in state {
            digest.append(UInt8(truncatingIfNeeded: word))
            digest.append(UInt8(truncatingIfNeeded: word >> 8))
            digest.append(UInt8(truncatingIfNeeded: word >> 16))
            digest.append(UInt8(truncatingIfNeeded: word >> 24))
        }
        return digest
    }

    // MARK: - Implementation

    private mutating func update(bytes: UnsafeRawBufferPointer) {
        messageLength &+= UInt64(bytes.count)
        var words = [UInt32](repeating: 0, count: 16)
        var index = 0

        // Complete a partial block first.
        if !pending.isEmpty {
            let needed = Self.blockSize - pending.count
            let take = min(needed, bytes.count)
            pending.append(contentsOf: UnsafeRawBufferPointer(rebasing: bytes[0..<take]))
            index = take
            if pending.count < Self.blockSize { return }
            pending.withUnsafeBytes { block in
                compress(block: block, words: &words)
            }
            pending.removeAll(keepingCapacity: true)
        }

        // Whole blocks straight from the input.
        while bytes.count - index >= Self.blockSize {
            let block = UnsafeRawBufferPointer(rebasing: bytes[index..<(index + Self.blockSize)])
            compress(block: block, words: &words)
            index += Self.blockSize
        }

        if index < bytes.count {
            pending.append(contentsOf: UnsafeRawBufferPointer(rebasing: bytes[index...]))
        }
    }

    @inline(__always)
    private static func rotateLeft(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value << count) | (value >> (32 - count))
    }

    private mutating func compress(block: UnsafeRawBufferPointer, words m: inout [UInt32]) {
        for t in 0..<16 {
            let i = t * 4
            m[t] = UInt32(block[i]) | UInt32(block[i + 1]) << 8
                | UInt32(block[i + 2]) << 16 | UInt32(block[i + 3]) << 24
        }

        var a = state[0], b = state[1], c = state[2], d = state[3]

        for i in 0..<64 {
            var f: UInt32
            let g: Int
            switch i {
            case 0..<16:
                f = (b & c) | (~b & d)
                g = i
            case 16..<32:
                f = (d & b) | (~d & c)
                g = (5 * i + 1) % 16
            case 32..<48:
                f = b ^ c ^ d
                g = (3 * i + 5) % 16
            default:
                f = c ^ (b | ~d)
                g = (7 * i) % 16
            }
            f = f &+ a &+ Self.constants[i] &+ m[g]
            a = d
            d = c
            c = b
            b = b &+ Self.rotateLeft(f, Self.shifts[i])
        }

        state[0] &+= a; state[1] &+= b; state[2] &+= c; state[3] &+= d
    }
}
