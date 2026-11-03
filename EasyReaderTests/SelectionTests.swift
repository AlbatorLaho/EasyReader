import XCTest
@testable import EasyReader

final class SelectionTests: XCTestCase {
    func testEmptyDefault() {
        let selection = Selection()
        XCTAssertEqual(selection.lowerBound, 0)
        XCTAssertEqual(selection.upperBound, 0)
        XCTAssertTrue(selection.isEmpty)
        XCTAssertEqual(selection.count, 0)
    }

    func testRangeConversionsRoundTrip() {
        let selection = Selection(3..<8)
        XCTAssertEqual(selection.count, 5)
        XCTAssertFalse(selection.isEmpty)
        XCTAssertEqual(Selection(NSRange(selection)), selection)
        XCTAssertEqual(Selection(CFRange(selection)), selection)
        XCTAssertEqual(Range<Int>(selection), 3..<8)
    }

    func testContains() {
        let selection = Selection(2..<4)
        XCTAssertFalse(selection.contains(1))
        XCTAssertTrue(selection.contains(2))
        XCTAssertTrue(selection.contains(3))
        XCTAssertFalse(selection.contains(4))
    }

    /// AX ranges are UTF-16 offsets; characters outside the BMP take two code units.
    func testUsesUTF16OffsetsWithEmoji() {
        let string = "😀 Hi"
        let hi = string.range(of: "Hi")!
        let selection = Selection(hi, in: string)
        XCTAssertEqual(selection.lowerBound, 3)
        XCTAssertEqual(selection.upperBound, 5)
        XCTAssertEqual(selection.startIndex(in: string), hi.lowerBound)
        XCTAssertEqual(selection.endIndex(in: string), hi.upperBound)
        let range = Range<String.Index>(selection, in: string)
        XCTAssertEqual(range.map { String(string[$0]) }, "Hi")
    }

    func testStringIndexRangeOutOfBoundsIsNil() {
        XCTAssertNil(Range<String.Index>(Selection(0..<10), in: "abc"))
    }

    /// Offsets past the end clamp (used to trap once the index was used).
    func testOutOfRangeOffsetIsClamped() {
        let string = "abc"
        XCTAssertEqual(Selection(0..<10).endIndex(in: string), string.endIndex)
        XCTAssertEqual(Selection(-2..<1).startIndex(in: string), string.startIndex)
    }

    /// Offsets inside a surrogate pair round down to the character boundary.
    func testOffsetInsideSurrogatePairRoundsDown() {
        let string = "a😀b"
        XCTAssertEqual(Selection(2..<2).startIndex(in: string).utf16Offset(in: string), 1)
        XCTAssertEqual(Selection(0..<2).endIndex(in: string).utf16Offset(in: string), 1)
    }
}
