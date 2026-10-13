import Foundation
import Testing
import CleanerCore
@testable import maccleaner

@Suite("Scan document JSON")
struct ScanDocumentJSONTests {
    @Test("round-trips through the shared encoder and decoder")
    func roundTrip() throws {
        let text = try ScanJSON.encode(Fixtures.document)
        let decoded = try ScanJSON.decode(ScanDocument.self, from: Data(text.utf8))
        #expect(decoded == Fixtures.document)
        #expect(try ScanJSON.encode(decoded) == text)
    }

    @Test("is pretty-printed with sorted keys and ISO 8601 dates")
    func formatting() throws {
        let text = try ScanJSON.encode(Fixtures.document)
        #expect(text.hasPrefix("{\n"))
        let findingsIndex = try #require(text.range(of: "\"findings\""))
        let summaryIndex = try #require(text.range(of: "\"summary\""))
        #expect(findingsIndex.lowerBound < summaryIndex.lowerBound)
        #expect(text.contains("\"modifiedAt\" : \"2023-11-14T22:13:20Z\""))
        #expect(text.contains("\"path\" : \"file:///Users/me/Library/Caches/a.db\""))
        #expect(text.contains("\"totalBytes\" : 2600000"))
        #expect(text.contains("\"totalFindings\" : 4"))
    }

    @Test("summary built from findings is consistent with them")
    func derivedSummary() {
        let summary = Fixtures.document.summary
        #expect(summary.totalFindings == 4)
        #expect(summary.totalBytes == 2_600_000)
        #expect(summary.byCategory == ["cleanup.userCaches": 2_500_000, "cleanup.logs": 100_000])
        #expect(summary.duration == 1.5)
    }

    @Test("a removal manifest round-trips too")
    func manifestRoundTrip() throws {
        let records = Fixtures.findings.map {
            RemovalRecord(finding: $0, trashedTo: URL(fileURLWithPath: "/tmp/trash/\($0.path.lastPathComponent)"),
                          succeeded: true, error: nil)
        }
        let manifest = RemovalManifest(id: Fixtures.uuid(9), startedAt: Fixtures.modified,
                                       mode: .trash, records: records)
        let text = try ScanJSON.encode(manifest)
        let decoded = try ScanJSON.decode(RemovalManifest.self, from: Data(text.utf8))
        #expect(decoded == manifest)
        #expect(decoded.bytesReclaimed == 2_600_000)
    }
}
