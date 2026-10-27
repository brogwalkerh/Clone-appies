import Testing
@testable import CleanerCore

@Suite("ByteFormatter")
struct ByteFormatterTests {
    @Test("formats decimal units with one decimal place", arguments: [
        (Int64(0), "0 B"),
        (Int64(1), "1 B"),
        (Int64(999), "999 B"),
        (Int64(1_000), "1 KB"),
        (Int64(1_500), "1.5 KB"),
        (Int64(350_000), "350 KB"),
        (Int64(999_949), "999.9 KB"),
        (Int64(999_950), "1 MB"),
        (Int64(1_000_000), "1 MB"),
        (Int64(12_400_000_000), "12.4 GB"),
        (Int64(12_000_000_000), "12 GB"),
        (Int64(2_500_000_000_000), "2.5 TB"),
        (Int64(-1_500), "-1.5 KB"),
    ])
    func formats(bytes: Int64, expected: String) {
        #expect(ByteFormatter.string(bytes) == expected)
    }
}
