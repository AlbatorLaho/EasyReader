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
