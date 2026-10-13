import Foundation
import Testing
import CleanerCore
@testable import maccleaner

@Suite("Table formatter")
struct TableFormatterTests {
    @Test("renders categories, totals and the largest findings")
    func snapshot() {
        let expected = """
        Category          Count       Size
        ----------------------------------
        User Cache Files      2     2.5 MB
        Log Files             2     100 KB
        ----------------------------------
        Total                 4     2.6 MB
        Scan took 1.5 s.

        Largest findings (top 4 of 4):
        1. [safe]      2 MB  /Users/me/Library/Caches/a.db
        2. [caution] 500 KB  /Users/me/Library/Caches/b.db
        3. [RISKY]    70 KB  /Users/me/Library/Logs/x.log
        4. [safe]     30 KB  /Users/me/Library/Logs/old/
        """
        #expect(TableFormatter.render(Fixtures.document) == expected)
    }

    @Test("limits the largest-findings list to topCount")
    func topCount() {
        let rendered = TableFormatter.render(Fixtures.document, topCount: 2)
        #expect(rendered.contains("Largest findings (top 2 of 4):"))
        #expect(rendered.contains("1. [safe]      2 MB  /Users/me/Library/Caches/a.db"))
        #expect(!rendered.contains("x.log"))
    }

    @Test("handles an empty scan")
    func empty() {
        let document = ScanDocument(findings: [], duration: 0.3)
        #expect(TableFormatter.render(document) == "No findings.\nScan took 0.3 s.")
    }

    @Test("category rows are sorted by bytes, then name")
    func rows() {
        let rows = TableFormatter.categoryRows(Fixtures.findings)
        #expect(rows.map(\.category.id) == ["cleanup.userCaches", "cleanup.logs"])
        #expect(rows.map(\.count) == [2, 2])
        #expect(rows.map(\.bytes) == [2_500_000, 100_000])
    }
}
