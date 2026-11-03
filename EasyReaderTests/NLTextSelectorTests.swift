import XCTest
@testable import EasyReader

final class NLTextSelectorTests: XCTestCase {
    private func text(of selection: Selection, in string: String) -> String? {
        Range<String.Index>(selection, in: string).map {
            String(string[$0]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func testForwardSentences() {
        let string = "First sentence. Second sentence. Third one."
        let selector = NLTextSelector(unit: .sentence)
        let first = selector.select(.forward, from: Selection(), in: string)
        XCTAssertEqual(text(of: first, in: string), "First sentence.")
        let second = selector.select(.forward, from: first, in: string)
        XCTAssertEqual(text(of: second, in: string), "Second sentence.")
        let third = selector.select(.forward, from: second, in: string)
        XCTAssertEqual(text(of: third, in: string), "Third one.")
    }

    func testForwardAtEndIsEmpty() {
        let string = "Only one."
        let selector = NLTextSelector(unit: .sentence)
        let end = Selection(string.startIndex..<string.endIndex, in: string)
        XCTAssertTrue(selector.select(.forward, from: end, in: string).isEmpty)
    }

    func testBackwardSentences() {
        let string = "First sentence. Second sentence. Third one."
        let selector = NLTextSelector(unit: .sentence)
        let third = Selection(string.range(of: "Third one.")!, in: string)
        let second = selector.select(.backward, from: third, in: string)
        XCTAssertEqual(text(of: second, in: string), "Second sentence.")
        let first = selector.select(.backward, from: second, in: string)
        XCTAssertEqual(text(of: first, in: string), "First sentence.")
    }

    func testBackwardAtStartIsEmpty() {
        let string = "Only one."
        let selector = NLTextSelector(unit: .sentence)
        XCTAssertTrue(selector.select(.backward, from: Selection(), in: string).isEmpty)
    }

    func testForwardParagraphs() {
        let string = "Para one. Still one.\n\nPara two."
        let selector = NLTextSelector(unit: .paragraph)
        let first = selector.select(.forward, from: Selection(), in: string)
        XCTAssertEqual(text(of: first, in: string), "Para one. Still one.")
        let second = selector.select(.forward, from: first, in: string)
        XCTAssertEqual(text(of: second, in: string), "Para two.")
    }

    func testHandlesNonBMPCharacters() {
        let string = "😀 Hello there. Bye now."
        let selector = NLTextSelector(unit: .sentence)
        let first = selector.select(.forward, from: Selection(), in: string)
        XCTAssertEqual(text(of: first, in: string), "😀 Hello there.")
        let second = selector.select(.forward, from: first, in: string)
        XCTAssertEqual(text(of: second, in: string), "Bye now.")
        let back = selector.select(.backward, from: second, in: string)
        XCTAssertEqual(text(of: back, in: string), "😀 Hello there.")
    }

    /// A selection starting inside the first character's UTF-16 surrogate pair rounds down to the start
    /// (used to make `enumerateTagsReversed` call `index(before:)` on the start index and trap).
    func testBackwardFromInsideLeadingSurrogatePair() {
        let string = "😀 Hi."
        XCTAssertTrue(NLTextSelector(unit: .sentence).select(.backward, from: Selection(1..<3), in: string).isEmpty)
    }
}
