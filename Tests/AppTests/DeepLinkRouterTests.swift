import XCTest
import ProtectionModule
@testable import Featherduster

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
        XCTAssertEqual(link("featherduster://smart-care"), .smartCare)
        XCTAssertEqual(link("FEATHERDUSTER://Smart-Care"), .smartCare, "scheme and route are case-insensitive")
        XCTAssertEqual(link("featherduster:///smart-care"), .smartCare, "route may arrive as the first path component")
    }

    func testCleanupWithAndWithoutScanner() {
        XCTAssertEqual(link("featherduster://cleanup"), .cleanup(scannerID: nil))
        XCTAssertEqual(link("featherduster://cleanup?scanner=cleanup.userCaches"),
                       .cleanup(scannerID: "cleanup.userCaches"))
        XCTAssertEqual(link("featherduster://cleanup?scanner="), .cleanup(scannerID: nil),
                       "an empty scanner value means an unrestricted scan")
    }

    func testPerformanceWithAndWithoutTask() {
        XCTAssertEqual(link("featherduster://performance"), .performance(taskID: nil))
        XCTAssertEqual(link("featherduster://performance?task=maintenance.freeRAM"),
                       .performance(taskID: "maintenance.freeRAM"))
        XCTAssertEqual(link("featherduster://performance?other=1&task=maintenance.flushDNS"),
                       .performance(taskID: "maintenance.flushDNS"))
    }

    func testProtectionWithAndWithoutScope() {
        XCTAssertEqual(link("featherduster://protection"), .protection(scope: nil))
        XCTAssertEqual(link("featherduster://protection?scope=quick"), .protection(scope: .quick))
        XCTAssertEqual(link("featherduster://protection?scope=Deep"), .protection(scope: .deep), "scope is case-insensitive")
        XCTAssertEqual(link("featherduster://protection?scope=everything"), .protection(scope: nil),
                       "an unknown scope keeps the current one rather than failing the link")
        XCTAssertEqual(link("featherduster://protection?scope="), .protection(scope: nil))
        XCTAssertEqual(link("featherduster:///protection?scope=normal"), .protection(scope: .normal))
    }

    func testScheduleAndActionSet() {
        let id = UUID(uuidString: "6F1D2C3B-0001-4A5B-9C8D-000000000001")!
        XCTAssertEqual(link("featherduster://schedule?id=\(id.uuidString)"), .schedule(id: id))
        XCTAssertEqual(link("featherduster://schedule?id=\(id.uuidString.lowercased())"), .schedule(id: id),
                       "UUIDs parse in either case")
        XCTAssertEqual(link("featherduster://action-set?id=\(id.uuidString)"), .actionSet(id: id))
        XCTAssertNil(link("featherduster://schedule"), "a schedule link needs an id")
        XCTAssertNil(link("featherduster://action-set?id=not-a-uuid"))
    }

    func testBadURLs() {
        XCTAssertNil(link("https://example.com/smart-care"), "wrong scheme")
        XCTAssertNil(link("featherduster://nope"), "unknown route")
        XCTAssertNil(link("featherduster://"), "no route")
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
