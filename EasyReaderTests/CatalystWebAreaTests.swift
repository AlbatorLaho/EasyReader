import Foundation
import Testing

@testable import EasyReader

/// `CatalystWebAreaReadableElement` itself needs Apple Books (Catalyst web views can't be hosted here); this covers
/// locating a paragraph's on-page part in its text.
struct CatalystWebAreaTests {
    @Test func wholeParagraph() {
        #expect(CatalystWebAreaReadableElement.locate("One. Two.", in: "One. Two.", fromEnd: true) == 0..<9)
    }

    /// The last paragraph on a spread shows its head.
    @Test func head() {
        #expect(CatalystWebAreaReadableElement.locate("One. Tw", in: "One. Two. Three.", fromEnd: false) == 0..<7)
    }

    /// The first paragraph on a spread shows its tail, which Books reports without its last character.
    @Test func tailGetsItsLastCharacterBack() {
        #expect(CatalystWebAreaReadableElement.locate("ee. Four", in: "One. Three. Four.", fromEnd: true) == 8..<17)
    }

    @Test func tailIsTheLastOccurrence() {
        #expect(CatalystWebAreaReadableElement.locate("go", in: "go on, go", fromEnd: true) == 7..<9)
        #expect(CatalystWebAreaReadableElement.locate("go", in: "go on, go", fromEnd: false) == 0..<2)
    }

    @Test func utf16Offsets() {
        #expect(CatalystWebAreaReadableElement.locate("‘My 😀 dad", in: "He said, ‘My 😀 dad’", fromEnd: false) == 9..<19)
    }

    @Test func notFound() {
        #expect(CatalystWebAreaReadableElement.locate("other text", in: "One. Two.", fromEnd: true) == nil)
    }
}

/// Finding the user's selection from what Books copies.
struct CatalystCopiedSelectionTests {
    @Test func excerptDropsQuotesAndCitation() {
        let copied = "“a sentence the reader selected”\n\nExcerpt From\nSample Book Title\nAuthor Name\nThis material may be protected by copyright."
        #expect(CatalystWebAreaReadableElement.excerpt(fromCopied: copied) == "a sentence the reader selected")
    }

    @Test func excerptKeepsPlainText() {
        #expect(CatalystWebAreaReadableElement.excerpt(fromCopied: "just text") == "just text")
    }

    @Test func excerptKeepsInnerQuotes() {
        let copied = "““Hi,” she said.”\n\nExcerpt From\nBook"
        #expect(CatalystWebAreaReadableElement.excerpt(fromCopied: copied) == "“Hi,” she said.")
    }

    @Test func locateOnSpread() {
        let text = "Two. One. Two. Three." as NSString
        // "Two." before the spread (0..<4) isn't taken.
        #expect(CatalystWebAreaReadableElement.locate(copied: "Two.", in: text, on: 5..<21) == 10..<14)
    }

    @Test func locateAcrossParagraphs() {
        let text = "First para.\nSecond para ends.\nThird." as NSString
        #expect(CatalystWebAreaReadableElement.locate(copied: "para.\n\nSecond para", in: text, on: 0..<36) == 6..<23)
    }

    @Test func locateOffSpread() {
        let text = "One. Two. Three. Four." as NSString
        #expect(CatalystWebAreaReadableElement.locate(copied: "One.", in: text, on: 10..<22) == nil)
    }
}
