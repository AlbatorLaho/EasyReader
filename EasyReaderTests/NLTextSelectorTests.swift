import Foundation
import Testing

@testable import EasyReader

struct NLTextSelectorTests {
    private func text(of selection: Selection, in string: String) -> String? {
        Range<String.Index>(selection, in: string).map {
            String(string[$0]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Every sentence, stepping from the start (forward) or the end (backward), in text order; at most 10.
    private func units(_ direction: Selection.Direction, in string: String) -> [String] {
        let selector = NLTextSelector(unit: .sentence)
        var units: [String] = []
        var current = direction == .forward ? Selection() : Selection(string.utf16.count..<string.utf16.count)
        while case let next = selector.select(direction, from: current, in: string), !next.isEmpty, units.count < 10 {
            units.append(text(of: next, in: string) ?? "")
            current = next
        }
        return direction == .forward ? units : units.reversed()
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

    /// Lines with nothing to read (imported HTML has many) are stepped over, both ways; only blanks left → empty.
    @Test func blankUnitsSkippedWithoutBlocks() {
        let string = "First one.\n\u{00A0}\n\u{FFFC}\n \nSecond one.\n\n\u{00A0}\n"
        let selector = NLTextSelector(unit: .sentence)
        let first = selector.select(.forward, from: Selection(), in: string, blocks: { _ in nil })
        #expect(text(of: first, in: string) == "First one.")
        let second = selector.select(.forward, from: first, in: string, blocks: { _ in nil })
        #expect(text(of: second, in: string) == "Second one.")
        #expect(selector.select(.forward, from: second, in: string, blocks: { _ in nil }).isEmpty)
        #expect(text(of: selector.select(.backward, from: second, in: string, blocks: { _ in nil }), in: string) == "First one.")
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

    /// Starting inside the first character's surrogate pair rounds down to the start (`enumerateTagsReversed` used to trap).
    @Test func backwardFromInsideLeadingSurrogatePair() {
        let string = "😀 Hi."
        #expect(NLTextSelector(unit: .sentence).select(.backward, from: Selection(1..<3), in: string).isEmpty)
    }

    /// NaturalLanguage splits Wikipedia-style citations ("1850.[" + "2] It grew…"); they stay with their sentence, both ways.
    @Test func citationsStayWithTheirSentence() {
        let string = "The city was founded in 1850.[2] It grew fast.[3][4]\nHistory\nThe first settlers came.[5]"
        let expected = ["The city was founded in 1850.[2]", "It grew fast.[3][4]", "History", "The first settlers came.[5]"]
        #expect(units(.forward, in: string) == expected)
        #expect(units(.backward, in: string) == expected)
    }

    /// NaturalLanguage makes a list number its own sentence ("81. " + "^ Bromley…"); it's read with the item, both ways.
    @Test func listLabelsStayWithTheirItem() {
        let string = "Notes end here.\n81. ^ Bromley, Allan G. (1990). Engines.\n82. ^ Collier, Bruce.\n3.\nNext line."
        let expected = ["Notes end here.", "81. ^ Bromley, Allan G. (1990).", "Engines.", "82. ^ Collier, Bruce.", "3.", "Next line."]
        #expect(units(.forward, in: string) == expected)
        #expect(units(.backward, in: string) == expected)
    }

    @Test(
        arguments: [
            ("81. ", true), (" iv) ", true), ("b. ", true), ("•", true), ("12345. ", false), ("Done. ", false), ("p. 34.", false),
            ("3.\n", false),
        ] as [(String, Bool)])
    func isListLabel(text: String, expected: Bool) {
        #expect(NLTextSelector.isListLabel(Substring(text)) == expected)
    }

    @Test(
        arguments: [
            ("1850.[2] It", "1850.[".utf16.count, "1850.[2] ".utf16.count),
            ("fast.[3][4]\nHistory", "fast.[".utf16.count, "fast.[3][4]\n".utf16.count),
            ("Open [ bracket", "Open [".utf16.count, "Open [".utf16.count),
            ("Not.[closed\nyet]", "Not.[".utf16.count, "Not.[".utf16.count),
            ("Mid wo[r]d", "Mid wo".utf16.count, "Mid wo".utf16.count),
        ] as [(String, Int, Int)])
    func skippingCitations(string: String, boundary: Int, expected: Int) {
        let index = String.Index(utf16Offset: boundary, in: string)
        #expect(NLTextSelector.skippingCitations(from: index, in: string).utf16Offset(in: string) == expected)
    }
}

/// Units stay within blocks reported separately (Chromium page text has no breaks between them).
struct BlockSelectionTests {
    // "Heading" + "First one. Second one." + U+FFFC (image) + "Last block.".
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

    /// Starting on the space after a sentence (PDFKit reports selections without it) must not skip the rest of the block.
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
