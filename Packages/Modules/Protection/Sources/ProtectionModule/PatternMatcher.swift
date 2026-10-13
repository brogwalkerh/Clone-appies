import Foundation

/// Streaming-safe matcher for `HexPattern`s.
///
/// Chunking contract: the caller feeds consecutive chunks of a file such that
/// each chunk (except the first) repeats at least `maxPatternLength` bytes of
/// the previous one, passing the absolute `chunkOffset` of the chunk's first
/// byte and the file's logical `fileSize`. Every bounded pattern (no `*` and
/// no open-ended `{n-}`) is then guaranteed to be found; patterns with an
/// unbounded skip are matched within a single chunk only, so a match whose
/// fixed parts straddle more than one chunk is missed. The same pattern may
/// be reported from two overlapping chunks; callers de-duplicate by name.
///
/// Matching is a linear scan with backtracking over tokens: simple and
/// correct rather than fast.
public struct PatternMatcher: Sendable {
    /// Upper bound on `maxPatternLength`; longer bounded spans are treated as
    /// if they were this long for overlap purposes.
    public static let maxPatternLengthCap = 4_096

    public let patterns: [HexPattern]
    /// Overlap the caller must keep between chunks: the largest bounded byte
    /// span of any pattern, capped at `maxPatternLengthCap`. 0 with no patterns.
    public let maxPatternLength: Int

    private let compiled: [Compiled]

    struct Compiled: Sendable {
        let pattern: HexPattern
        let span: Int
        let isBounded: Bool
        let firstByte: UInt8?
    }

    public init(patterns: [HexPattern]) {
        self.patterns = patterns
        var compiled: [Compiled] = []
        var longest = 0
        for pattern in patterns where !pattern.tokens.isEmpty {
            let span = pattern.tokens.reduce(0) { $0 + $1.boundedSpan }
            let bounded = !pattern.tokens.contains(where: \.isUnbounded)
            var first: UInt8?
            if case .byte(let b) = pattern.tokens[0] { first = b }
            compiled.append(Compiled(pattern: pattern, span: span, isBounded: bounded, firstByte: first))
            longest = max(longest, span)
        }
        self.compiled = compiled
        self.maxPatternLength = min(longest, Self.maxPatternLengthCap)
    }

    /// Names of the patterns matching inside `data` (each name at most once).
    public func matches(in data: Data, fileSize: Int64, chunkOffset: Int64) -> [String] {
        guard !data.isEmpty, !compiled.isEmpty else { return [] }
        var names: [String] = []
        var seen = Set<String>()
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            for entry in compiled where !seen.contains(entry.pattern.name) {
                if Self.matches(entry, in: bytes, fileSize: fileSize, chunkOffset: chunkOffset) {
                    seen.insert(entry.pattern.name)
                    names.append(entry.pattern.name)
                }
            }
        }
        return names
    }

    /// Convenience for whole-file data.
    public func matches(in data: Data) -> [String] {
        matches(in: data, fileSize: Int64(data.count), chunkOffset: 0)
    }

    /// True when any pattern has a `fromEnd` offset (those need the exact file size).
    public var usesEndOffsets: Bool {
        compiled.contains { if case .fromEnd = $0.pattern.offset { return true } else { return false } }
    }

    // MARK: - Implementation

    private static func matches(_ entry: Compiled, in bytes: UnsafeBufferPointer<UInt8>,
                                fileSize: Int64, chunkOffset: Int64) -> Bool {
        let count = bytes.count
        let tokens = entry.pattern.tokens
        switch entry.pattern.offset {
        case .absolute(let start):
            let local = Int64(start) - chunkOffset
            guard local >= 0, local < Int64(count) else { return false }
            return matchTokens(tokens, 0, bytes, Int(local))
        case .fromEnd(let back):
            let local = fileSize - Int64(back) - chunkOffset
            guard local >= 0, local < Int64(count) else { return false }
            return matchTokens(tokens, 0, bytes, Int(local))
        case .any:
            // A bounded pattern cannot start later than count - span.
            let lastStart = entry.isBounded ? count - entry.span : count - 1
            guard lastStart >= 0 else { return false }
            if let first = entry.firstByte {
                var i = 0
                while i <= lastStart {
                    if bytes[i] == first, matchTokens(tokens, 1, bytes, i + 1) { return true }
                    i += 1
                }
                return false
            }
            for start in 0...lastStart where matchTokens(tokens, 0, bytes, start) {
                return true
            }
            return false
        }
    }

    /// Backtracking match of `tokens[index...]` at `position`.
    private static func matchTokens(_ tokens: [PatternToken], _ index: Int,
                                    _ bytes: UnsafeBufferPointer<UInt8>, _ position: Int) -> Bool {
        var index = index
        var position = position
        let count = bytes.count
        while index < tokens.count {
            switch tokens[index] {
            case .byte(let expected):
                guard position < count, bytes[position] == expected else { return false }
                position += 1
            case .wildcardByte:
                guard position < count else { return false }
                position += 1
            case .nibbleHigh(let high):
                guard position < count, bytes[position] >> 4 == high else { return false }
                position += 1
            case .nibbleLow(let low):
                guard position < count, bytes[position] & 0x0F == low else { return false }
                position += 1
            case .skipAny:
                return matchSkip(tokens, index + 1, bytes, position, minimum: 0, maximum: count - position)
            case .skipRange(let minimum, let maximum):
                return matchSkip(tokens, index + 1, bytes, position, minimum: minimum,
                                 maximum: min(maximum, count - position))
            }
            index += 1
        }
        return true
    }

    /// Tries every skip length from `minimum` to `maximum` for the token after
    /// a skip. When that token is a fixed byte, only positions holding it are tried.
    private static func matchSkip(_ tokens: [PatternToken], _ index: Int,
                                  _ bytes: UnsafeBufferPointer<UInt8>, _ position: Int,
                                  minimum: Int, maximum: Int) -> Bool {
        guard minimum <= maximum else { return false }
        if index >= tokens.count { return true }
        var next: UInt8?
        if case .byte(let b) = tokens[index] { next = b }
        var skip = minimum
        while skip <= maximum {
            let candidate = position + skip
            if let next {
                guard candidate < bytes.count else { return false }
                if bytes[candidate] == next, matchTokens(tokens, index, bytes, candidate) { return true }
            } else if matchTokens(tokens, index, bytes, candidate) {
                return true
            }
            skip += 1
        }
        return false
    }
}
