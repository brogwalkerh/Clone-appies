import XCTest
import ProtectionModule
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

    func testProtectionWithAndWithoutScope() {
        XCTAssertEqual(link("maccleaner://protection"), .protection(scope: nil))
        XCTAssertEqual(link("maccleaner://protection?scope=quick"), .protection(scope: .quick))
        XCTAssertEqual(link("maccleaner://protection?scope=Deep"), .protection(scope: .deep), "scope is case-insensitive")
        XCTAssertEqual(link("maccleaner://protection?scope=everything"), .protection(scope: nil),
                       "an unknown scope keeps the current one rather than failing the link")
        XCTAssertEqual(link("maccleaner://protection?scope="), .protection(scope: nil))
        XCTAssertEqual(link("maccleaner:///protection?scope=normal"), .protection(scope: .normal))
    }

    func testScheduleAndActionSet() {
        let id = UUID(uuidString: "6F1D2C3B-0001-4A5B-9C8D-000000000001")!
        XCTAssertEqual(link("maccleaner://schedule?id=\(id.uuidString)"), .schedule(id: id))
        XCTAssertEqual(link("maccleaner://schedule?id=\(id.uuidString.lowercased())"), .schedule(id: id),
                       "UUIDs parse in either case")
        XCTAssertEqual(link("maccleaner://action-set?id=\(id.uuidString)"), .actionSet(id: id))
        XCTAssertNil(link("maccleaner://schedule"), "a schedule link needs an id")
        XCTAssertNil(link("maccleaner://action-set?id=not-a-uuid"))
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
            .performance(taskID: "maintenance.freeRAM"),
            .protection(scope: nil),
            .protection(scope: .deep),
            .schedule(id: UUID()),
            .actionSet(id: UUID())
        ]
        for original in links {
            let url = try XCTUnwrap(original.url)
            XCTAssertEqual(DeepLink(url: url), original)
        }
    }
}
