import Foundation

/// One ClamAV `.ndb` body signature.
public struct HexPattern: Sendable, Hashable {
    public let name: String
    /// ClamAV target type: 0 any file, 1 PE, 5 graphics, 6 ELF, 7 ASCII, 9 Mach-O, 10 PDF.
    public let target: Int
    public let offset: PatternOffset
    public let tokens: [PatternToken]

    public init(name: String, target: Int, offset: PatternOffset, tokens: [PatternToken]) {
        self.name = name
        self.target = target
        self.offset = offset
        self.tokens = tokens
    }
}

public enum PatternOffset: Sendable, Hashable {
    /// `*`: the pattern may start anywhere.
    case any
    /// `n`: the pattern starts exactly `n` bytes into the file.
    case absolute(Int)
    /// `EOF-n`: the pattern starts `n` bytes before the end of the file.
    case fromEnd(Int)
}

public enum PatternToken: Sendable, Hashable {
    /// `XY`: one fixed byte.
    case byte(UInt8)
    /// `??`: any one byte.
    case wildcardByte
    /// `X?`: the high nibble is fixed, the low nibble is anything.
    case nibbleHigh(UInt8)
    /// `?X`: the low nibble is fixed, the high nibble is anything.
    case nibbleLow(UInt8)
    /// `*`: zero or more bytes.
    case skipAny
    /// `{n}`, `{n-m}`, `{-m}`, `{n-}`: between `min` and `max` bytes
    /// (`max == Int.max` for an open upper bound).
    case skipRange(min: Int, max: Int)

    /// True for `*` and open-ended `{n-}` skips.
    var isUnbounded: Bool {
        switch self {
        case .skipAny: true
        case .skipRange(_, let max): max == Int.max
        default: false
        }
    }

    /// True for any skip token.
    var isSkip: Bool {
        switch self {
        case .skipAny, .skipRange: true
        default: false
        }
    }

    /// Fewest bytes this token can consume.
    var minSpan: Int {
        switch self {
        case .byte, .wildcardByte, .nibbleHigh, .nibbleLow: 1
        case .skipAny: 0
        case .skipRange(let min, _): min
        }
    }

    /// Largest number of bytes this token can consume (for unbounded skips,
    /// the minimum, since the rest is "the rest of the chunk").
    var boundedSpan: Int {
        switch self {
        case .byte, .wildcardByte, .nibbleHigh, .nibbleLow: 1
        case .skipAny: 0
        case .skipRange(let min, let max): max == Int.max ? min : max
        }
    }
}

public enum HexPatternError: Error, Sendable, Hashable {
    case empty
    case invalidCharacter(String, at: Int)
    case unterminatedBrace
    case invalidRange(String)
    /// `(aa|bb)` alternation is not supported in v1.
    case unsupportedAlternation
    /// `[n-m]`, `!`, anchors and other ClamAV extensions.
    case unsupportedSyntax(String)
    case leadingOrTrailingSkip
    case noFixedBytes
}

/// Parses the ClamAV hex body grammar into `PatternToken`s.
enum HexPatternParser {
    /// Largest finite skip bound accepted in `{n}`, `{n-m}`, `{-m}` and
    /// `{n-}`. Real signatures use far less; larger values are rejected as
    /// malformed so span arithmetic cannot overflow.
    static let maxSkipLength = 1 << 20

    static func parse(_ text: String) throws -> [PatternToken] {
        let chars = Array(text)
        guard !chars.isEmpty else { throw HexPatternError.empty }
        var tokens: [PatternToken] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "*":
                tokens.append(.skipAny)
                i += 1
            case "{":
                guard let close = chars[i...].firstIndex(of: "}") else { throw HexPatternError.unterminatedBrace }
                let inner = String(chars[(i + 1)..<close])
                tokens.append(try parseRange(inner))
                i = close + 1
            case "(", "|":
                throw HexPatternError.unsupportedAlternation
            case "[", "!", "]", ")":
                throw HexPatternError.unsupportedSyntax(String(c))
            case "?":
                guard i + 1 < chars.count else { throw HexPatternError.invalidCharacter("?", at: i) }
                let next = chars[i + 1]
                if next == "?" {
                    tokens.append(.wildcardByte)
                } else if let nibble = hexValue(next) {
                    tokens.append(.nibbleLow(nibble))
                } else {
                    throw HexPatternError.invalidCharacter(String(next), at: i + 1)
                }
                i += 2
            default:
                guard let high = hexValue(c) else { throw HexPatternError.invalidCharacter(String(c), at: i) }
                guard i + 1 < chars.count else { throw HexPatternError.invalidCharacter(String(c), at: i) }
                let next = chars[i + 1]
                if next == "?" {
                    tokens.append(.nibbleHigh(high))
                } else if let low = hexValue(next) {
                    tokens.append(.byte(high << 4 | low))
                } else {
                    throw HexPatternError.invalidCharacter(String(next), at: i + 1)
                }
                i += 2
            }
        }
        guard let first = tokens.first, let last = tokens.last else { throw HexPatternError.empty }
        if first.isSkip || last.isSkip { throw HexPatternError.leadingOrTrailingSkip }
        // At least one token must constrain a byte value.
        guard tokens.contains(where: { token in
            switch token {
            case .byte, .nibbleHigh, .nibbleLow: true
            default: false
            }
        }) else {
            throw HexPatternError.noFixedBytes
        }
        return tokens
    }

    private static func parseRange(_ inner: String) throws -> PatternToken {
        if let dash = inner.firstIndex(of: "-") {
            let lowText = String(inner[..<dash])
            let highText = String(inner[inner.index(after: dash)...])
            if lowText.isEmpty && highText.isEmpty { throw HexPatternError.invalidRange(inner) }
            let low = lowText.isEmpty ? 0 : Int(lowText)
            let high = highText.isEmpty ? Int.max : Int(highText)
            guard let low, let high, low >= 0, high >= low, low <= maxSkipLength,
                  highText.isEmpty || high <= maxSkipLength else {
                throw HexPatternError.invalidRange(inner)
            }
            return .skipRange(min: low, max: high)
        }
        guard let n = Int(inner), n >= 0, n <= maxSkipLength else { throw HexPatternError.invalidRange(inner) }
        return .skipRange(min: n, max: n)
    }

    static func hexValue(_ c: Character) -> UInt8? {
        guard let ascii = c.asciiValue else { return nil }
        switch ascii {
        case 0x30...0x39: return ascii - 0x30
        case 0x61...0x66: return ascii - 0x61 + 10
        case 0x41...0x46: return ascii - 0x41 + 10
        default: return nil
        }
    }
}
