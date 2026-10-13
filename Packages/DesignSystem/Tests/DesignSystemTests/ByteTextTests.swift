import XCTest
@testable import DesignSystem

final class ByteTextTests: XCTestCase {
    func testComponentsUseDecimalUnits() {
        let gb = ByteText.components(12_400_000_000)
        XCTAssertEqual(gb.unit, "GB")
        XCTAssertTrue(gb.value.hasPrefix("12"), "expected 12.4, got \(gb.value)")

        let bytes = ByteText.components(532)
        XCTAssertEqual(bytes.value, "532")
        XCTAssertEqual(bytes.unit, "B")

        XCTAssertEqual(ByteText.components(0).unit, "B")
        XCTAssertEqual(ByteText.components(-5).value, "0")
    }

    func testThemedColorContrastShiftsTowardExtremes() {
        let mid = RGB(0.5, 0.5, 0.5)
        let darker = mid.shifted(by: -0.2)
        let lighter = mid.shifted(by: 0.2)
        XCTAssertLessThan(darker.red, mid.red)
        XCTAssertGreaterThan(lighter.red, mid.red)
    }
}
