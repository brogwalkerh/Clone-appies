import Foundation

/// SHA-256 (FIPS 180-4), pure Swift, one-shot convenience API.
public struct SHA256: Sendable {
    /// Digest of `data` as 32 bytes.
    public static func hash(_ data: Data) -> [UInt8] {
        var hasher = StreamingSHA256()
        hasher.update(data)
        return hasher.finalize()
    }

    /// Lower-case hexadecimal rendering of a digest.
    public static func hexString(_ digest: [UInt8]) -> String {
        let table: [Character] = Array("0123456789abcdef")
        var out = String()
        out.reserveCapacity(digest.count * 2)
        for byte in digest {
            out.append(table[Int(byte >> 4)])
            out.append(table[Int(byte & 0x0F)])
        }
        return out
    }
}

/// Incremental SHA-256. Feed any number of `update` calls, then `finalize`
/// once; the hasher must not be reused afterwards.
public struct StreamingSHA256: Sendable {
    private static let initialState: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]

    private static let roundConstants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    private static let blockSize = 64

    private var state: [UInt32] = StreamingSHA256.initialState
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
        for shift in stride(from: 56, through: 0, by: -8) {
            padding.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }
        padding.withUnsafeBytes { raw in
            update(bytes: raw)
        }
        var digest: [UInt8] = []
        digest.reserveCapacity(32)
        for word in state {
            digest.append(UInt8(truncatingIfNeeded: word >> 24))
            digest.append(UInt8(truncatingIfNeeded: word >> 16))
            digest.append(UInt8(truncatingIfNeeded: word >> 8))
            digest.append(UInt8(truncatingIfNeeded: word))
        }
        return digest
    }

    // MARK: - Implementation

    private mutating func update(bytes: UnsafeRawBufferPointer) {
        messageLength &+= UInt64(bytes.count)
        var schedule = [UInt32](repeating: 0, count: 64)
        var index = 0

        // Complete a partial block first.
        if !pending.isEmpty {
            let needed = Self.blockSize - pending.count
            let take = min(needed, bytes.count)
            pending.append(contentsOf: UnsafeRawBufferPointer(rebasing: bytes[0..<take]))
            index = take
            if pending.count < Self.blockSize { return }
            pending.withUnsafeBytes { block in
                compress(block: block, schedule: &schedule)
            }
            pending.removeAll(keepingCapacity: true)
        }

        // Whole blocks straight from the input.
        while bytes.count - index >= Self.blockSize {
            let block = UnsafeRawBufferPointer(rebasing: bytes[index..<(index + Self.blockSize)])
            compress(block: block, schedule: &schedule)
            index += Self.blockSize
        }

        if index < bytes.count {
            pending.append(contentsOf: UnsafeRawBufferPointer(rebasing: bytes[index...]))
        }
    }

    @inline(__always)
    private static func rotateRight(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value >> count) | (value << (32 - count))
    }

    private mutating func compress(block: UnsafeRawBufferPointer, schedule w: inout [UInt32]) {
        for t in 0..<16 {
            let i = t * 4
            w[t] = UInt32(block[i]) << 24 | UInt32(block[i + 1]) << 16
                | UInt32(block[i + 2]) << 8 | UInt32(block[i + 3])
        }
        for t in 16..<64 {
            let s0 = Self.rotateRight(w[t - 15], 7) ^ Self.rotateRight(w[t - 15], 18) ^ (w[t - 15] >> 3)
            let s1 = Self.rotateRight(w[t - 2], 17) ^ Self.rotateRight(w[t - 2], 19) ^ (w[t - 2] >> 10)
            w[t] = w[t - 16] &+ s0 &+ w[t - 7] &+ s1
        }

        var a = state[0], b = state[1], c = state[2], d = state[3]
        var e = state[4], f = state[5], g = state[6], h = state[7]

        for t in 0..<64 {
            let bigSigma1 = Self.rotateRight(e, 6) ^ Self.rotateRight(e, 11) ^ Self.rotateRight(e, 25)
            let choose = (e & f) ^ (~e & g)
            let temp1 = h &+ bigSigma1 &+ choose &+ Self.roundConstants[t] &+ w[t]
            let bigSigma0 = Self.rotateRight(a, 2) ^ Self.rotateRight(a, 13) ^ Self.rotateRight(a, 22)
            let majority = (a & b) ^ (a & c) ^ (b & c)
            let temp2 = bigSigma0 &+ majority
            h = g
            g = f
            f = e
            e = d &+ temp1
            d = c
            c = b
            b = a
            a = temp1 &+ temp2
        }

        state[0] &+= a; state[1] &+= b; state[2] &+= c; state[3] &+= d
        state[4] &+= e; state[5] &+= f; state[6] &+= g; state[7] &+= h
    }
}
