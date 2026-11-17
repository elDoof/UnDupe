import XCTest
@testable import UnDupeCore

final class CountFormatTests: XCTestCase {

    func testUsesTheSingularOnlyForExactlyOne() {
        XCTAssertEqual(CountFormat.string(1, "file"), "1 file")
        XCTAssertEqual(CountFormat.string(0, "file"), "0 files")
        XCTAssertEqual(CountFormat.string(2, "file"), "2 files")
    }

    func testUsesAnIrregularPluralWhenGiven() {
        XCTAssertEqual(CountFormat.string(1, "copy", plural: "copies"), "1 copy")
        XCTAssertEqual(CountFormat.string(4, "copy", plural: "copies"), "4 copies")
    }

    func testGroupsDigitsInLargeCounts() {
        // The separator is the user's locale's, so compare against the same
        // formatter style rather than a hard-coded comma.
        let expected = NumberFormatter.localizedString(from: 1_234_567, number: .decimal)

        XCTAssertEqual(CountFormat.number(1_234_567), expected)
        XCTAssertEqual(CountFormat.string(1_234_567, "file"), "\(expected) files")
        XCTAssertNotEqual(CountFormat.number(1_234_567), "1234567")
    }

    func testNounAgreesWithTheCountOnItsOwn() {
        XCTAssertEqual(CountFormat.noun(1, "item"), "item")
        XCTAssertEqual(CountFormat.noun(5, "item"), "items")
    }
}
