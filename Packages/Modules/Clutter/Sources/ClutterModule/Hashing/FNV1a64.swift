import Foundation

/// 64-bit FNV-1a, used as the cheap head+tail prefilter in the duplicates
/// pipeline. Not collision resistant: survivors always get a full SHA-256.
struct FNV1a64: Sendable, Hashable {
    static let offsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
    static let prime: UInt64 = 0x0000_0100_0000_01b3

    private(set) var value: UInt64 = FNV1a64.offsetBasis

    init() {}

    mutating func update(_ data: Data) {
        var hash = value
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* Self.prime
        }
        value = hash
    }

    static func hash(_ data: Data) -> UInt64 {
        var hasher = FNV1a64()
        hasher.update(data)
        return hasher.value
    }
}
