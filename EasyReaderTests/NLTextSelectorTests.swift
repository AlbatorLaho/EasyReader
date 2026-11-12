import Foundation
import Testing

@testable import EasyReader

struct NLTextSelectorTests {
    private func text(of selection: Selection, in string: String) -> String? {
        Range<String.Index>(selection, in: string).map {
            String(string[$0]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    @Test func forwardSentences() {
        let string = "First sentence. Second sentence. Third one."
        let selector = NLTextSelector(unit: .sentence)
        let first = selector.select(.forward, from: Selection(), in: string)
        #expect(text(of: first, in: string) == "First sentence.")
        let second = selector.select(.forward, from: first, in: string)
        #expect(text(of: second, in: string) == "Second sentence.")
        let third = selector.select(.forward, from: second, in: string)
        #expect(text(of: third, in: string) == "Third one.")
    }

    @Test func forwardAtEndIsEmpty() {
        let string = "Only one."
        let selector = NLTextSelector(unit: .sentence)
        let end = Selection(string.startIndex..<string.endIndex, in: string)
        #expect(selector.select(.forward, from: end, in: string).isEmpty)
    }

    @Test func backwardSentences() throws {
        let string = "First sentence. Second sentence. Third one."
        let selector = NLTextSelector(unit: .sentence)
        let third = Selection(try #require(string.range(of: "Third one.")), in: string)
        let second = selector.select(.backward, from: third, in: string)
        #expect(text(of: second, in: string) == "Second sentence.")
        let first = selector.select(.backward, from: second, in: string)
        #expect(text(of: first, in: string) == "First sentence.")
    }

    @Test func backwardAtStartIsEmpty() {
        let string = "Only one."
        let selector = NLTextSelector(unit: .sentence)
        #expect(selector.select(.backward, from: Selection(), in: string).isEmpty)
    }

    @Test func forwardParagraphs() {
        let string = "Para one. Still one.\n\nPara two."
        let selector = NLTextSelector(unit: .paragraph)
        let first = selector.select(.forward, from: Selection(), in: string)
        #expect(text(of: first, in: string) == "Para one. Still one.")
        let second = selector.select(.forward, from: first, in: string)
        #expect(text(of: second, in: string) == "Para two.")
    }

    @Test func backwardParagraphs() {
        let string = "Para one. Still one.\n\nPara two."
        let selector = NLTextSelector(unit: .paragraph)
        let second = selector.select(.backward, from: Selection(string.utf16.count..<string.utf16.count), in: string)
        #expect(text(of: second, in: string) == "Para two.")
        let first = selector.select(.backward, from: second, in: string)
        #expect(text(of: first, in: string) == "Para one. Still one.")
        #expect(selector.select(.backward, from: first, in: string).isEmpty)
    }

    /// From a collapsed cursor inside a sentence: forward reads the rest of it, backward the part before the cursor.
    @Test func fromCollapsedCursorMidSentence() {
        let string = "First sentence. Second sentence. Third one."
        let cursor = Selection(19..<19)  // "Sec|ond"
        let selector = NLTextSelector(unit: .sentence)
        #expect(text(of: selector.select(.forward, from: cursor, in: string), in: string) == "ond sentence.")
        #expect(text(of: selector.select(.backward, from: cursor, in: string), in: string) == "Sec")
    }

    @Test func handlesNonBMPCharacters() {
        let string = "😀 Hello there. Bye now."
        let selector = NLTextSelector(unit: .sentence)
        let first = selector.select(.forward, from: Selection(), in: string)
        #expect(text(of: first, in: string) == "😀 Hello there.")
        let second = selector.select(.forward, from: first, in: string)
        #expect(text(of: second, in: string) == "Bye now.")
        let back = selector.select(.backward, from: second, in: string)
        #expect(text(of: back, in: string) == "😀 Hello there.")
    }

    /// A selection starting inside the first character's UTF-16 surrogate pair rounds down to the start
    /// (used to make `enumerateTagsReversed` call `index(before:)` on the start index and trap).
    @Test func backwardFromInsideLeadingSurrogatePair() {
        let string = "😀 Hi."
        #expect(NLTextSelector(unit: .sentence).select(.backward, from: Selection(1..<3), in: string).isEmpty)
    }
}

/// `TextSelector.select(_:from:in:blocks:)`: units stay within blocks reported separately (Chromium page text has no
/// line breaks between them).
struct BlockSelectionTests {
    /// "Heading" + "First one. Second one." + U+FFFC (image) + "Last block." run together, blocks given separately.
    private let string = "HeadingFirst one. Second one.\u{FFFC}Last block."
    private var blocks: [Selection] { [Selection(0..<7), Selection(7..<29), Selection(29..<30), Selection(30..<41)] }

    private func block(_ offset: Int) -> Selection? { blocks.first { $0.contains(offset) } }

    private func text(_ selection: Selection) -> String {
        (string as NSString).substring(with: NSRange(selection)).trimmingCharacters(in: .whitespaces)
    }

    @Test func forwardStaysInBlocksAndSkipsBlankOnes() {
        let selector = NLTextSelector(unit: .sentence)
        var current = Selection()
        var read: [String] = []
        for _ in 0..<5 {
            current = selector.select(.forward, from: current, in: string, blocks: block)
            read.append(text(current))
        }
        #expect(read == ["Heading", "First one.", "Second one.", "Last block.", ""])
        #expect(current == Selection(41..<41))
    }

    @Test func backwardStaysInBlocks() {
        let selector = NLTextSelector(unit: .sentence)
        var current = Selection(41..<41)
        var read: [String] = []
        for _ in 0..<5 {
            current = selector.select(.backward, from: current, in: string, blocks: block)
            read.append(text(current))
        }
        #expect(read == ["Last block.", "Second one.", "First one.", "Heading", ""])
    }

    /// Starting on the space after a sentence (a selection reported without its trailing space, e.g. by PDFKit): the
    /// space alone is blank, but the rest of the block must not be skipped.
    @Test func blankStepDoesNotSkipRestOfBlock() {
        let selector = NLTextSelector(unit: .sentence)
        let forward = selector.select(.forward, from: Selection(7..<17), in: string, blocks: block)
        #expect(text(forward) == "Second one.")
        let backward = selector.select(.backward, from: Selection(18..<29), in: string, blocks: block)
        #expect(text(backward) == "First one.")
    }

    /// A block starting inside a grapheme cluster is read from the cluster's start, with offsets from there.
    @Test func blockSplittingGraphemeKeepsOffsets() {
        let string = "👍🏽 One. Two."
        let count = string.utf16.count
        let selector = NLTextSelector(unit: .sentence)
        let found = selector.select(.forward, from: Selection(2..<2), in: string, blocks: { _ in Selection(2..<count) })
        #expect((string as NSString).substring(with: NSRange(found)).trimmingCharacters(in: .whitespaces) == "👍🏽 One.")
    }

    @Test func paragraphUnitIsTheBlock() {
        let selector = NLTextSelector(unit: .paragraph)
        let first = selector.select(.forward, from: Selection(), in: string, blocks: block)
        let second = selector.select(.forward, from: first, in: string, blocks: block)
        #expect([text(first), text(second)] == ["Heading", "First one. Second one."])
    }

    @Test func backwardParagraphsStayInBlocks() {
        let selector = NLTextSelector(unit: .paragraph)
        var current = Selection(41..<41)
        var read: [String] = []
        for _ in 0..<4 {
            current = selector.select(.backward, from: current, in: string, blocks: block)
            read.append(text(current))
        }
        #expect(read == ["Last block.", "First one. Second one.", "Heading", ""])
    }

    /// Without block information, the whole string is used (the heading runs into the first sentence).
    @Test func unknownBlocksFallBackToWholeString() {
        let selector = NLTextSelector(unit: .sentence)
        #expect(text(selector.select(.forward, from: Selection(), in: string, blocks: { _ in nil })) == "HeadingFirst one.")
    }
}
