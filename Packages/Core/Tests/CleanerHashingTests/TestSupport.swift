import Foundation

/// Deterministic pseudo-random bytes (xorshift64). The reference digest in
/// `SHA256Tests` was produced from the same generator.
func pseudoRandomData(count: Int, seed: UInt64 = 0x9E37_79B9_7F4A_7C15) -> Data {
    var x = seed
    var bytes = [UInt8](repeating: 0, count: count)
    for i in 0..<count {
        x ^= x &<< 13
        x ^= x &>> 7
        x ^= x &<< 17
        bytes[i] = UInt8(truncatingIfNeeded: x)
    }
    return Data(bytes)
}
