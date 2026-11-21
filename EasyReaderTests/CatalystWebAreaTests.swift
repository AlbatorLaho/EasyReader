import AppKit
import Testing

@testable import EasyReader

/// Locating a paragraph's on-spread part (the element itself needs Apple Books).
struct CatalystWebAreaTests {
    /// Only a sideways move is WebKit scrolling off the page grid; a turn settling can still change y and size.
    @Test(
        arguments: [
            (CGRect(x: 0, y: 40, width: 1200, height: 800), nil),
            (CGRect(x: 0.5, y: 0, width: 1200, height: 800), nil),
            (CGRect(x: -1200, y: 0, width: 1200, height: 800), -1200),
            (CGRect(x: 600, y: 0, width: 1200, height: 800), 600),
        ] as [(CGRect, CGFloat?)])
    func sidewaysShift(moved: CGRect, expected: CGFloat?) {
        let frame = CGRect(x: 0, y: 0, width: 1200, height: 820)
        #expect(CatalystWebAreaReadableElement.sidewaysShift(from: frame, to: moved) == expected)
    }

    /// A turn moves a chapter shown before and after by a spread (its width plus a gap), either way.
    @Test(
        arguments: [
            (CGRect(x: -966, y: 0, width: 906, height: 800), true),  // measured in Books
            (CGRect(x: 966, y: 4, width: 906, height: 790), true),
            (CGRect(x: -850, y: 0, width: 906, height: 800), true),
            (CGRect(x: -450, y: 0, width: 906, height: 800), false),  // mid-animation or WebKit's scroll
            (CGRect(x: 0, y: 0, width: 906, height: 800), false),
        ] as [(CGRect, Bool)])
    func hasTurned(moved: CGRect, expected: Bool) {
        let chapter = AXElement.application(pid: 1)
        let frame = CGRect(x: 0, y: 0, width: 906, height: 800)
        #expect(CatalystWebAreaReadableElement.hasTurned(from: [chapter: frame], to: [chapter: moved]) == expected)
        // Another chapter's frame says nothing.
        #expect(!CatalystWebAreaReadableElement.hasTurned(from: [chapter: frame], to: [AXElement.application(pid: 2): moved]))
    }

    @Test(
        arguments: [
            ("One. Two.", "One. Two.", true, 0..<9),  // the whole paragraph
            ("One. Tw", "One. Two. Three.", false, 0..<7),  // the last paragraph on a spread shows its head
            ("ee. Four", "One. Three. Four.", true, 8..<17),  // a tail: Books reports it without its last character
            ("go", "go on, go", true, 7..<9),  // a tail is the last occurrence
            ("go", "go on, go", false, 0..<2),
            ("‘My 😀 dad", "He said, ‘My 😀 dad’", false, 9..<19),  // UTF-16 offsets
            ("other text", "One. Two.", true, nil),
        ] as [(String, String, Bool, Range<Int>?)])
    func locatesOnSpreadPart(value: String, paragraph: String, fromEnd: Bool, expected: Range<Int>?) {
        #expect(CatalystWebAreaReadableElement.locate(value, in: paragraph, fromEnd: fromEnd) == expected)
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

    /// Keys that can select text in Books flag a selection to copy on the next read.
    @Test(
        arguments: [
            ([.shift], "→", true),  // extending a selection
            ([.shift, .option], "←", true),
            ([.shift, .capsLock], "A", true),
            ([.command], "a", true),  // select all
            ([.command, .capsLock], "A", true),
            ([], "→", false),  // turning a page
            ([.command], "c", false),
            ([], "a", false),
            ([.option], "a", false),
        ] as [(NSEvent.ModifierFlags, String, Bool)])
    func keyMaySelect(flags: NSEvent.ModifierFlags, key: String, expected: Bool) {
        #expect(CatalystWebAreaReadableElement.maySelect(flags, key: key) == expected)
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

/// When reading moves on to the next chapter.
struct CatalystChapterEndTests {
    private let text = "One. Two.\n\n" as NSString

    private func isEnd(_ unit: Range<Int>, spoken: String, reached: Int?) -> Bool {
        CatalystWebAreaReadableElement.isChapterEnd(unit: Selection(unit), in: text, spoken: spoken as NSString, reached: reached)
    }

    @Test func lastWordOfLastUnit() {
        #expect(isEnd(5..<9, spoken: "Two.", reached: 0))
        #expect(!isEnd(0..<4, spoken: "One.", reached: 0))
    }

    @Test func notBeforeTheLastWord() {
        let text = "One. Two three.\n" as NSString
        let spoken = "Two three." as NSString
        #expect(!CatalystWebAreaReadableElement.isChapterEnd(unit: Selection(5..<15), in: text, spoken: spoken, reached: 0))
        #expect(CatalystWebAreaReadableElement.isChapterEnd(unit: Selection(5..<15), in: text, spoken: spoken, reached: 4))
        #expect(!CatalystWebAreaReadableElement.isChapterEnd(unit: Selection(5..<15), in: text, spoken: spoken, reached: nil))
    }

    /// Speech reports no word in a unit without any (a scene break): it ends the chapter all the same.
    @Test func unitWithoutWords() {
        let text = "One.\n* * *" as NSString
        #expect(CatalystWebAreaReadableElement.isChapterEnd(unit: Selection(5..<10), in: text, spoken: "* * *", reached: nil))
    }

    @Test func emptyUnit() {
        #expect(!isEnd(9..<9, spoken: "", reached: nil))
    }
}
