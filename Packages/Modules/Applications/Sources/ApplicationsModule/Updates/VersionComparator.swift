import Foundation

/// Compares version strings the way Sparkle and the App Store do.
///
/// Strings are split on `.`, `-`, space, `(` and `)`, and every piece is
/// further split into numeric and alphabetic runs. Numeric components compare
/// numerically ("1.10" > "1.9"); a pre-release suffix sorts below the bare
/// version ("2.0b1" < "2.0"); trailing zero components are insignificant
/// ("1.2" == "1.2.0"); a build in parentheses is compared after the version
/// ("1.2.3 (456)" < "1.2.3 (457)").
public struct VersionComparator: Sendable {
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let left = tokenize(a)
        let right = tokenize(b)
        let count = max(left.count, right.count)
        for index in 0..<count {
            switch (index < left.count ? left[index] : nil, index < right.count ? right[index] : nil) {
            case (nil, nil):
                return .orderedSame
            case (let l?, nil):
                // "2.0b1" vs "2.0": a pre-release suffix sorts below.
                if case .text = l { return .orderedAscending }
                if left[index...].allSatisfy({ $0.isZero }) { return .orderedSame }
                return .orderedDescending
            case (nil, let r?):
                if case .text = r { return .orderedDescending }
                if right[index...].allSatisfy({ $0.isZero }) { return .orderedSame }
                return .orderedAscending
            case (let l?, let r?):
                let result = l.compare(r)
                if result != .orderedSame { return result }
            }
        }
        return .orderedSame
    }

    /// True when `candidate` is strictly newer than `installed`.
    public static func isNewer(_ candidate: String, than installed: String) -> Bool {
        compare(candidate, installed) == .orderedDescending
    }

    enum Token: Equatable {
        case number(UInt64)
        case text(String)

        var isZero: Bool {
            if case .number(0) = self { return true }
            return false
        }

        func compare(_ other: Token) -> ComparisonResult {
            switch (self, other) {
            case (.number(let l), .number(let r)):
                return l < r ? .orderedAscending : (l > r ? .orderedDescending : .orderedSame)
            case (.text(let l), .text(let r)):
                let lo = l.lowercased(), ro = r.lowercased()
                return lo < ro ? .orderedAscending : (lo > ro ? .orderedDescending : .orderedSame)
            case (.number, .text):
                // A number beats a pre-release word at the same position: "2.0.1" > "2.0b1".
                return .orderedDescending
            case (.text, .number):
                return .orderedAscending
            }
        }
    }

    static func tokenize(_ version: String) -> [Token] {
        let separators: Set<Character> = [".", "-", " ", "(", ")", "_", "+"]
        var tokens: [Token] = []
        var digits = ""
        var letters = ""
        func flush() {
            if !digits.isEmpty {
                tokens.append(.number(UInt64(digits) ?? UInt64.max))
                digits = ""
            }
            if !letters.isEmpty {
                tokens.append(.text(letters))
                letters = ""
            }
        }
        for character in version {
            if separators.contains(character) {
                flush()
            } else if character.isNumber {
                if !letters.isEmpty { flush() }
                digits.append(character)
            } else {
                if !digits.isEmpty { flush() }
                letters.append(character)
            }
        }
        flush()
        return tokens
    }
}
