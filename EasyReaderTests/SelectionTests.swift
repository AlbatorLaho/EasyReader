import Foundation
import Testing

@testable import EasyReader

struct SelectionTests {
    @Test func emptyDefault() {
        let selection = Selection()
        #expect(selection.lowerBound == 0)
        #expect(selection.upperBound == 0)
        #expect(selection.isEmpty)
        #expect(selection.count == 0)
    }

    @Test func rangeConversionsRoundTrip() {
        let selection = Selection(3..<8)
        #expect(selection.count == 5)
        #expect(!selection.isEmpty)
        #expect(Selection(NSRange(selection)) == selection)
        #expect(Selection(CFRange(selection)) == selection)
        #expect(Range<Int>(selection) == 3..<8)
    }

    @Test func notFoundRangeIsNil() {
        #expect(Selection(CFRange(location: NSNotFound, length: 3)) == nil)
        #expect(Selection(CFRange(location: kCFNotFound, length: 0)) == nil)
    }

    @Test(arguments: [(1, false), (2, true), (3, true), (4, false)])
    func contains(offset: Int, expected: Bool) {
        #expect(Selection(2..<4).contains(offset) == expected)
    }

    /// AX ranges are UTF-16 offsets; characters outside the BMP take two code units.
    @Test func usesUTF16OffsetsWithEmoji() throws {
        let string = "😀 Hi"
        let hi = try #require(string.range(of: "Hi"))
        let selection = Selection(hi, in: string)
        #expect(selection.lowerBound == 3)
        #expect(selection.upperBound == 5)
        #expect(selection.startIndex(in: string) == hi.lowerBound)
        #expect(selection.endIndex(in: string) == hi.upperBound)
        let range = Range<String.Index>(selection, in: string)
        #expect(range.map { String(string[$0]) } == "Hi")
    }

    @Test func stringIndexRangeOutOfBoundsIsNil() {
        #expect(Range<String.Index>(Selection(0..<10), in: "abc") == nil)
    }

    /// Offsets past the end clamp (used to trap once the index was used).
    @Test func outOfRangeOffsetIsClamped() {
        let string = "abc"
        #expect(Selection(0..<10).endIndex(in: string) == string.endIndex)
        #expect(Selection(-2..<1).startIndex(in: string) == string.startIndex)
    }

    /// Offsets inside a surrogate pair round down to the character boundary.
    @Test func offsetInsideSurrogatePairRoundsDown() {
        let string = "a😀b"
        #expect(Selection(2..<2).startIndex(in: string).utf16Offset(in: string) == 1)
        #expect(Selection(0..<2).endIndex(in: string).utf16Offset(in: string) == 1)
    }
}

struct WebAreaLocateTests {
    @Test(
        arguments: [
            ("bold", 10, Selection(8..<12)),  // two past: snaps back
            ("bold", 8, Selection(8..<12)),  // exact
            ("bold", 6, Selection(8..<12)),  // two before
            ("nope", 8, Selection(8..<12)),  // not found: kept as measured
            ("", 3, Selection(3..<3)),
        ] as [(String, Int, Selection)])
    func locatesNearestOccurrence(string: String, offset: Int, expected: Selection) {
        #expect(WebAreaReadableElement.locate(string, near: offset, in: "Second  bold text", tolerance: 4) == expected)
    }
}
