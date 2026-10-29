import Foundation
import Testing
import CleanerCore
import CleanerCoreTesting
@testable import ProtectionModule

@Suite("SignatureDatabase")
struct SignatureDatabaseTests {
    @Test func hdbParsesAndMatchesMD5() {
        let db = database(hdb: """
        \(eicarMD5):68:Eicar-Test-Signature
        this is not a signature
        0123456789abcdef0123456789abcdef:*:Any-Size
        tooshort:10:Bad
        \(eicarMD5):notasize:Bad
        \(eicarMD5):10:
        """)
        #expect(db.stats == .init(hashSignatures: 2, patternSignatures: 0, allowlisted: 0, skippedLines: 4))
        #expect(db.match(md5: eicarMD5, sha256: "", size: 68) == "Eicar-Test-Signature")
        #expect(db.match(md5: eicarMD5.uppercased(), sha256: "", size: 68) == "Eicar-Test-Signature")
        #expect(db.match(md5: eicarMD5, sha256: "", size: 69) == nil)
        #expect(db.match(md5: "0123456789abcdef0123456789abcdef", sha256: "", size: 1) == "Any-Size")
        #expect(db.match(md5: "0123456789abcdef0123456789abcdef", sha256: "", size: 1 << 40) == "Any-Size")
    }

    @Test func hsbParsesAndMatchesSHA256() {
        let db = database(hsb: """
        \(eicarSHA256):68:Eicar-Test-Signature:73:255
        \(eicarMD5):68:WrongLength
        """)
        #expect(db.stats.hashSignatures == 1)
        #expect(db.stats.skippedLines == 1)
        #expect(db.match(md5: "", sha256: eicarSHA256, size: 68) == "Eicar-Test-Signature")
        #expect(db.match(md5: "", sha256: eicarSHA256, size: 1) == nil)
    }

    @Test func ndbParsesOffsetsTargetsAndSkipsMalformed() {
        let db = database(ndb: """
        Any:0:*:4142
        Abs:9:12:4142{2-4}43
        End:1:EOF-4:41424344
        Alternation:0:*:41(42|43)
        MissingField:0:4142
        BadTarget:x:*:4142
        BadOffset:0:EOF:4142
        BadHex:0:*:41zz
        LeadingSkip:0:*:*4142
        :0:*:4142
        """)
        #expect(db.stats.patternSignatures == 3)
        #expect(db.stats.skippedLines == 7)
        let byName = Dictionary(uniqueKeysWithValues: db.patterns.map { ($0.name, $0) })
        #expect(byName["Any"]?.offset == .any)
        #expect(byName["Any"]?.target == 0)
        #expect(byName["Abs"]?.offset == .absolute(12))
        #expect(byName["Abs"]?.target == 9)
        #expect(byName["Abs"]?.tokens == [.byte(0x41), .byte(0x42), .skipRange(min: 2, max: 4), .byte(0x43)])
        #expect(byName["End"]?.offset == .fromEnd(4))
    }

    @Test func ign2RemovesMatchesAndPatterns() {
        var db = database(hdb: "\(eicarMD5):68:Eicar-Test-Signature",
                          ndb: "Eicar-Test-Signature-Pattern:0:*:4142\nOther:0:*:4344")
        #expect(db.match(md5: eicarMD5, sha256: "", size: 68) != nil)
        db.load(ign2: """
        Eicar-Test-Signature
        legacy.ndb:3:Eicar-Test-Signature-Pattern

        """)
        #expect(db.stats.allowlisted == 2)
        #expect(db.match(md5: eicarMD5, sha256: "", size: 68) == nil)
        #expect(db.patterns.map(\.name) == ["Other"])
        #expect(db.isAllowlisted("Eicar-Test-Signature"))
        #expect(!db.isAllowlisted("Other"))
    }

    @Test func ign2NameWithMD5FieldUsesTheName() {
        var db = database(ndb: "Withdrawn.Pattern:0:*:4142\nOther:0:*:4344")
        db.load(ign2: "Withdrawn.Pattern:\(eicarMD5)\n:\(eicarMD5)")
        #expect(db.isAllowlisted("Withdrawn.Pattern"))
        #expect(!db.isAllowlisted(eicarMD5))
        #expect(db.patterns.map(\.name) == ["Other"])
        #expect(db.stats.allowlisted == 1)
        #expect(db.stats.skippedLines == 1)
    }

    @Test func commentsAndBlankLinesAreSilent() {
        let db = database(hdb: "# a comment\n\n   \n\(eicarMD5):68:Eicar-Test-Signature\r\n")
        #expect(db.stats.hashSignatures == 1)
        #expect(db.stats.skippedLines == 0)
    }

    @Test func loadsDirectoryByExtension() throws {
        let fs: MockFileSystem = [
            "/sigs/a.hdb": .file("\(eicarMD5):68:Eicar-Test-Signature"),
            "/sigs/b.hsb": .file("\(eicarSHA256):*:Eicar-SHA"),
            "/sigs/c.ndb": .file("Pattern:0:*:4142"),
            "/sigs/d.ign2": .file("Ignored"),
            "/sigs/README.md": .file("not a signature file"),
            "/sigs/e.txt": .file("\(eicarMD5):68:ShouldNotLoad"),
        ]
        var db = SignatureDatabase()
        try db.load(contentsOf: URL(fileURLWithPath: "/sigs"), fileSystem: fs)
        #expect(db.stats == .init(hashSignatures: 2, patternSignatures: 1, allowlisted: 1, skippedLines: 0))
        #expect(db.match(md5: eicarMD5, sha256: "", size: 68) == "Eicar-Test-Signature")
        #expect(db.match(md5: "", sha256: eicarSHA256, size: 5) == "Eicar-SHA")
        #expect(throws: (any Error).self) {
            try db.load(contentsOf: URL(fileURLWithPath: "/missing"), fileSystem: fs)
        }
    }

    @Test func bundledStarterContainsEicar() {
        let db = SignatureDatabase.bundledStarter()
        #expect(db.stats.hashSignatures == 2)
        #expect(db.stats.patternSignatures == 5)
        #expect(db.stats.skippedLines == 0)
        #expect(db.match(md5: eicarMD5, sha256: "", size: 68) == "Eicar-Test-Signature")
        #expect(db.match(md5: "", sha256: eicarSHA256, size: 68) == "Eicar-Test-Signature")
        #expect(db.patterns.map(\.name).contains("Eicar-Test-Signature-Pattern"))
        let matcher = PatternMatcher(patterns: db.patterns)
        #expect(matcher.matches(in: Data(eicar.utf8)) == ["Eicar-Test-Signature-Pattern"])
    }
}
