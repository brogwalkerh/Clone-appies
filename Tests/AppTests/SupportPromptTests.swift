import XCTest
@testable import Featherduster

/// The Smart Care support card's rule (App/State/SupportPrompt.swift).
final class SupportPromptTests: XCTestCase {
    private let policy = SupportPromptPolicy()

    func testHiddenUntilOneGigabyteReclaimed() {
        XCTAssertFalse(policy.shouldShow(bytesReclaimed: 0, answered: false))
        XCTAssertFalse(policy.shouldShow(bytesReclaimed: 999_999_999, answered: false))
        XCTAssertTrue(policy.shouldShow(bytesReclaimed: 1_000_000_000, answered: false))
        XCTAssertTrue(policy.shouldShow(bytesReclaimed: 12_400_000_000, answered: false))
    }

    func testNeverShownAgainOnceAnswered() {
        XCTAssertFalse(policy.shouldShow(bytesReclaimed: 12_400_000_000, answered: true))
    }

    func testThresholdIsConfigurable() {
        let custom = SupportPromptPolicy(minimumBytesReclaimed: 10)
        XCTAssertTrue(custom.shouldShow(bytesReclaimed: 10, answered: false))
    }

    func testSponsorsLinkIsTheGitHubSponsorsPage() {
        XCTAssertEqual(SupportLinks.sponsors.absoluteString, "https://github.com/sponsors/brogwalkerh")
        XCTAssertEqual(SupportLinks.sponsors.scheme, "https")
    }
}
