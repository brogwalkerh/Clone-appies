import Foundation
import Testing
@testable import ProtectionModule

@Suite("Pattern grammar")
struct HexPatternParserTests {
    @Test func everyTokenKind() throws {
        let tokens = try HexPatternParser.parse("4142??4?{3}{2-5}{-4}{6-}*?2Ff")
        #expect(tokens == [
            .byte(0x41), .byte(0x42), .wildcardByte, .nibbleHigh(4),
            .skipRange(min: 3, max: 3), .skipRange(min: 2, max: 5), .skipRange(min: 0, max: 4),
            .skipRange(min: 6, max: Int.max), .skipAny, .nibbleLow(2), .byte(0xFF),
        ])
    }

    @Test func rejectsAlternationAndBadSyntax() {
        #expect(throws: HexPatternError.unsupportedAlternation) { try HexPatternParser.parse("41(42|43)") }
        #expect(throws: HexPatternError.unsupportedSyntax("[")) { try HexPatternParser.parse("41[2-3]42") }
        #expect(throws: HexPatternError.unterminatedBrace) { try HexPatternParser.parse("41{2") }
        #expect(throws: HexPatternError.invalidRange("-")) { try HexPatternParser.parse("41{-}42") }
        #expect(throws: HexPatternError.invalidRange("5-2")) { try HexPatternParser.parse("41{5-2}42") }
        #expect(throws: HexPatternError.leadingOrTrailingSkip) { try HexPatternParser.parse("*4142") }
        #expect(throws: HexPatternError.leadingOrTrailingSkip) { try HexPatternParser.parse("4142{2}") }
        #expect(throws: HexPatternError.noFixedBytes) { try HexPatternParser.parse("????") }
        #expect(throws: HexPatternError.noFixedBytes) { try HexPatternParser.parse("??{2}??") }
        #expect(throws: Never.self) { try HexPatternParser.parse("4???") }
        #expect(throws: HexPatternError.empty) { try HexPatternParser.parse("") }
        #expect(throws: (any Error).self) { try HexPatternParser.parse("4") }
        #expect(throws: (any Error).self) { try HexPatternParser.parse("4g") }
    }
}

@Suite("PatternMatcher")
struct PatternMatcherTests {
    private func pattern(_ hexText: String, name: String = "P", target: Int = 0,
                         offset: PatternOffset = .any) throws -> HexPattern {
        HexPattern(name: name, target: target, offset: offset, tokens: try HexPatternParser.parse(hexText))
    }

    private func matches(_ hexText: String, _ data: String, offset: PatternOffset = .any) throws -> Bool {
        let matcher = PatternMatcher(patterns: [try pattern(hexText, offset: offset)])
        return matcher.matches(in: Data(data.utf8)) == ["P"]
    }

    @Test func fixedBytes() throws {
        #expect(try matches(hex("ABC"), "xxABCxx"))
        #expect(try !matches(hex("ABC"), "xxABxx"))
        #expect(try !matches(hex("ABC"), ""))
    }

    @Test func wildcardByte() throws {
        #expect(try matches("41??43", "ABC"))
        #expect(try matches("41??43", "AZC"))
        #expect(try !matches("41??43", "AC"))
    }

    @Test func nibbleWildcards() throws {
        // 4? matches 0x40...0x4F ("@" through "O"); ?1 matches 0x01, 0x11, ..., "A" (0x41), "a" (0x61).
        #expect(try matches("4?", "O"))
        #expect(try !matches("4?", "P"))
        #expect(try matches("?1", "a"))
        #expect(try matches("?1", "A"))
        #expect(try !matches("?1", "B"))
        #expect(try matches("414?43", "ABC"))
    }

    @Test func skipRanges() throws {
        #expect(try matches("41{2}43", "AxxC"))
        #expect(try !matches("41{2}43", "AxC"))
        #expect(try !matches("41{2}43", "AxxxC"))
        #expect(try matches("41{1-3}43", "AxC"))
        #expect(try matches("41{1-3}43", "AxxxC"))
        #expect(try !matches("41{1-3}43", "AC"))
        #expect(try !matches("41{1-3}43", "AxxxxC"))
        #expect(try matches("41{-2}43", "AC"))
        #expect(try matches("41{-2}43", "AxxC"))
        #expect(try !matches("41{-2}43", "AxxxC"))
        #expect(try matches("41{2-}43", "AxxC"))
        #expect(try matches("41{2-}43", "Axxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx-C"))
        #expect(try !matches("41{2-}43", "AxC"))
    }

    @Test func skipAny() throws {
        #expect(try matches("41*43", "AC"))
        #expect(try matches("41*43", "A..........C"))
        #expect(try matches("41*42*43", "A.B..C"))
        #expect(try !matches("41*42*43", "A.C..B"))
        #expect(try matches("41*43", "AxCAC"))   // backtracks to a later C after a failed branch
    }

    @Test func backtrackingAcrossSkips() throws {
        // First "B" after "A" is not followed by "CD"; the matcher must try the next one.
        #expect(try matches("41{1-5}4243", "A..B.BC"))
        #expect(try matches("41*424344", "ABCxBCD"))
    }

    @Test func absoluteOffset() throws {
        #expect(try matches(hex("ABC"), "xxxxxABC", offset: .absolute(5)))
        #expect(try !matches(hex("ABC"), "xxxxABC", offset: .absolute(5)))
        #expect(try matches(hex("ABC"), "ABC", offset: .absolute(0)))
        #expect(try !matches(hex("ABC"), "AB", offset: .absolute(0)))
        #expect(try !matches(hex("ABC"), "ABC", offset: .absolute(10)))
    }

    @Test func endOffset() throws {
        #expect(try matches(hex("ABC"), "xxxxABC", offset: .fromEnd(3)))
        #expect(try !matches(hex("ABC"), "xxxABCx", offset: .fromEnd(3)))
        #expect(try matches(hex("ABC"), "xxxABCx", offset: .fromEnd(4)))
        #expect(try !matches(hex("ABC"), "AB", offset: .fromEnd(3)))
    }

    @Test func offsetsAcrossChunks() throws {
        let matcher = PatternMatcher(patterns: [
            try pattern(hex("ABC"), name: "abs", offset: .absolute(1_000)),
            try pattern(hex("XYZ"), name: "end", offset: .fromEnd(3)),
        ])
        var file = Data(repeating: 0x2E, count: 2_000)
        file.replaceSubrange(1_000..<1_003, with: Data("ABC".utf8))
        file.replaceSubrange(1_997..<2_000, with: Data("XYZ".utf8))
        let first = file.subdata(in: 0..<1_100)
        let second = file.subdata(in: 900..<2_000)
        #expect(matcher.matches(in: first, fileSize: 2_000, chunkOffset: 0) == ["abs"])
        #expect(Set(matcher.matches(in: second, fileSize: 2_000, chunkOffset: 900)) == ["abs", "end"])
        #expect(matcher.matches(in: second, fileSize: 2_001, chunkOffset: 900) == ["abs"])
    }

    @Test func chunkBoundaryWithOverlap() throws {
        let matcher = PatternMatcher(patterns: [try pattern(hex("ABCDE"))])
        #expect(matcher.maxPatternLength == 5)
        var file = pseudoRandomData(count: 40)
        file.replaceSubrange(18..<23, with: Data("ABCDE".utf8))
        let overlap = matcher.maxPatternLength
        let first = file.subdata(in: 0..<20)
        let withOverlap = file.subdata(in: (20 - overlap)..<40)
        let withoutOverlap = file.subdata(in: 20..<40)
        #expect(matcher.matches(in: first, fileSize: 40, chunkOffset: 0).isEmpty)
        #expect(matcher.matches(in: withOverlap, fileSize: 40, chunkOffset: Int64(20 - overlap)) == ["P"])
        #expect(matcher.matches(in: withoutOverlap, fileSize: 40, chunkOffset: 20).isEmpty)
    }

    @Test func maxPatternLengthUsesBoundedSpansAndCap() throws {
        #expect(PatternMatcher(patterns: []).maxPatternLength == 0)
        #expect(try PatternMatcher(patterns: [pattern("4142{2-7}??43")]).maxPatternLength == 11)
        #expect(try PatternMatcher(patterns: [pattern("41*42")]).maxPatternLength == 2)
        #expect(try PatternMatcher(patterns: [pattern("41{3-}42")]).maxPatternLength == 5)
        #expect(try PatternMatcher(patterns: [pattern("41{9000}42")]).maxPatternLength == 4_096)
        #expect(try PatternMatcher(patterns: [pattern("4142"), pattern("41{10}42", name: "Q")]).maxPatternLength == 12)
    }

    @Test func unboundedPatternMatchesWithinOneChunkOnly() throws {
        let matcher = PatternMatcher(patterns: [try pattern("41*5a")])
        let data = Data("A.........Z".utf8)
        #expect(matcher.matches(in: data) == ["P"])
        // Split so the fixed parts land in different chunks: documented limitation.
        #expect(matcher.matches(in: data.subdata(in: 0..<5), fileSize: 11, chunkOffset: 0).isEmpty)
        #expect(matcher.matches(in: data.subdata(in: 3..<11), fileSize: 11, chunkOffset: 3).isEmpty)
    }

    @Test func eachNameReportedOnce() throws {
        let matcher = PatternMatcher(patterns: [try pattern("41"), try pattern("41", name: "P")])
        #expect(matcher.matches(in: Data("AAAA".utf8)) == ["P"])
    }

    @Test func multiplePatternsAndMisses() throws {
        let matcher = PatternMatcher(patterns: [
            try pattern(hex("AB"), name: "ab"), try pattern(hex("CD"), name: "cd"), try pattern(hex("EF"), name: "ef"),
        ])
        #expect(Set(matcher.matches(in: Data("xxCDxxABxx".utf8))) == ["ab", "cd"])
    }
}

@Suite("File type detection")
struct FileTypeDetectionTests {
    @Test func magicBytes() {
        #expect(DetectedFileType.detect(head: Data([0xFE, 0xED, 0xFA, 0xCE, 0, 0, 0, 0])) == .machO)
        #expect(DetectedFileType.detect(head: Data([0xCF, 0xFA, 0xED, 0xFE, 7, 0, 0, 1])) == .machO)
        #expect(DetectedFileType.detect(head: Data([0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 2])) == .machO)
        #expect(DetectedFileType.detect(head: Data([0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 0x41])) == .unknown)   // Java class
        #expect(DetectedFileType.detect(head: Data("MZ\u{90}\0".utf8)) == .pe)
        #expect(DetectedFileType.detect(head: Data([0x7F, 0x45, 0x4C, 0x46, 2, 1])) == .elf)
        #expect(DetectedFileType.detect(head: Data("#!/bin/sh\n".utf8)) == .script)
        #expect(DetectedFileType.detect(head: Data("%PDF-1.7".utf8)) == .pdf)
        #expect(DetectedFileType.detect(head: Data([0xFF, 0xD8, 0xFF, 0xE0])) == .jpeg)
        #expect(DetectedFileType.detect(head: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) == .png)
        #expect(DetectedFileType.detect(head: Data("hello".utf8)) == .unknown)
        #expect(DetectedFileType.detect(head: Data()) == .unknown)
        #expect(DetectedFileType.detect(head: Data([0x7F])) == .unknown)
    }

    @Test func targetsAndExecutability() {
        #expect(DetectedFileType.pe.clamTarget == 1)
        #expect(DetectedFileType.elf.clamTarget == 6)
        #expect(DetectedFileType.machO.clamTarget == 9)
        #expect(DetectedFileType.unknown.clamTarget == nil)
        #expect(DetectedFileType.allCases.filter(\.isExecutable) == [.machO, .pe, .elf, .script])
    }
}
