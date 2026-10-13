import Foundation
import Testing
@testable import ApplicationsModule

@Suite("VersionComparator")
struct VersionComparatorTests {
    static let table: [(String, String, ComparisonResult)] = [
        ("1.10", "1.9", .orderedDescending),
        ("1.9", "1.10", .orderedAscending),
        ("2.0", "2.0b1", .orderedDescending),
        ("2.0b1", "2.0", .orderedAscending),
        ("1.2.3 (456)", "1.2.3 (457)", .orderedAscending),
        ("1.2.3 (457)", "1.2.3 (456)", .orderedDescending),
        ("1.2.3 (456)", "1.2.3 (456)", .orderedSame),
        ("1.2.3", "1.2.3", .orderedSame),
        ("", "", .orderedSame),
        ("1.2", "1.2.0", .orderedSame),
        ("1.2.0.0", "1.2", .orderedSame),
        ("1.2.1", "1.2", .orderedDescending),
        ("1.2.3 (456)", "1.2.3", .orderedDescending),
        ("1.2.4", "1.2.3 (999)", .orderedDescending),
        ("10.0", "9.9.9", .orderedDescending),
        ("2.0b2", "2.0b1", .orderedDescending),
        ("2.0b1", "2.0rc1", .orderedAscending),
        ("2.0rc1", "2.0", .orderedAscending),
        ("1.0.0-beta", "1.0.0", .orderedAscending),
        ("1.0.0-beta.2", "1.0.0-beta.1", .orderedDescending),
        ("2.0.1", "2.0b9", .orderedDescending),
        ("3.0 beta", "2.9", .orderedDescending),
        ("457", "456", .orderedDescending),
        ("456", "456", .orderedSame),
        ("1.2.3", "1.2.3-", .orderedSame),
        ("v1.2", "V1.2", .orderedSame),
        ("1.2a", "1.2A", .orderedSame),
    ]

    @Test(arguments: table.indices)
    func compare(_ index: Int) {
        let (a, b, expected) = Self.table[index]
        #expect(VersionComparator.compare(a, b) == expected, "\(a) vs \(b)")
    }

    @Test func isNewer() {
        #expect(VersionComparator.isNewer("1.10", than: "1.9"))
        #expect(!VersionComparator.isNewer("1.9", than: "1.10"))
        #expect(!VersionComparator.isNewer("1.9", than: "1.9"))
    }

    @Test func tokenizerSplitsNumericAndAlphaRuns() {
        #expect(VersionComparator.tokenize("2.0b1") == [.number(2), .number(0), .text("b"), .number(1)])
        #expect(VersionComparator.tokenize("1.2.3 (456)") == [.number(1), .number(2), .number(3), .number(456)])
        #expect(VersionComparator.tokenize("99999999999999999999") == [.number(UInt64.max)])
    }
}
