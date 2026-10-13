import XCTest
@testable import MacCleaner

/// Pure parsing tests for `DeepLink` (App/Navigation/DeepLinkRouter.swift).
final class DeepLinkRouterTests: XCTestCase {
    private func link(_ string: String, file: StaticString = #filePath, line: UInt = #line) -> DeepLink? {
        guard let url = URL(string: string) else {
            XCTFail("Not a URL: \(string)", file: file, line: line)
            return nil
        }
        return DeepLink(url: url)
    }

    func testSmartCare() {
        XCTAssertEqual(link("maccleaner://smart-care"), .smartCare)
        XCTAssertEqual(link("MACCLEANER://Smart-Care"), .smartCare, "scheme and route are case-insensitive")
        XCTAssertEqual(link("maccleaner:///smart-care"), .smartCare, "route may arrive as the first path component")
    }

    func testCleanupWithAndWithoutScanner() {
        XCTAssertEqual(link("maccleaner://cleanup"), .cleanup(scannerID: nil))
        XCTAssertEqual(link("maccleaner://cleanup?scanner=cleanup.userCaches"),
                       .cleanup(scannerID: "cleanup.userCaches"))
        XCTAssertEqual(link("maccleaner://cleanup?scanner="), .cleanup(scannerID: nil),
                       "an empty scanner value means an unrestricted scan")
    }

    func testPerformanceWithAndWithoutTask() {
        XCTAssertEqual(link("maccleaner://performance"), .performance(taskID: nil))
        XCTAssertEqual(link("maccleaner://performance?task=maintenance.freeRAM"),
                       .performance(taskID: "maintenance.freeRAM"))
        XCTAssertEqual(link("maccleaner://performance?other=1&task=maintenance.flushDNS"),
                       .performance(taskID: "maintenance.flushDNS"))
    }

    func testBadURLs() {
        XCTAssertNil(link("https://example.com/smart-care"), "wrong scheme")
        XCTAssertNil(link("maccleaner://nope"), "unknown route")
        XCTAssertNil(link("maccleaner://"), "no route")
        XCTAssertNil(link("mailto:someone@example.com"))
    }

    func testURLRoundTrip() throws {
        let links: [DeepLink] = [
            .smartCare,
            .cleanup(scannerID: nil),
            .cleanup(scannerID: "cleanup.logs"),
            .performance(taskID: "maintenance.freeRAM")
        ]
        for original in links {
            let url = try XCTUnwrap(original.url)
            XCTAssertEqual(DeepLink(url: url), original)
        }
    }
}
