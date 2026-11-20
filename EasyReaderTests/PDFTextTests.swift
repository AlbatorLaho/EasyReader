import AppKit
import Testing

@testable import EasyReader

struct PDFTextTests {
    typealias Info = PDFReadableElement.LeafStyle

    @Test func flattenedKeepsOffsets() {
        let (flat, lineBreaks) = PDFReadableElement.flattened("One line\nwraps 😀 here.\r\nEnd")
        #expect(flat == "One line wraps 😀 here.  End")
        #expect(lineBreaks == [8, 23, 24])
        #expect(flat.utf16.count == "One line\nwraps 😀 here.\r\nEnd".utf16.count)
    }

    /// Word joiners keep the length (offsets map back to the leaf); a hyphen that's part of the word stays.
    @Test func dehyphenateJoinsWordsBrokenAtLineEnds() {
        let value = "be-\ncause self-\naware X-\nRay 3-\nd"
        let (flat, lineBreaks) = PDFReadableElement.flattened(value)
        var units = Array(flat.utf16)
        PDFReadableElement.dehyphenate(&units, lineBreaks: lineBreaks) { $0 == "because" }
        #expect(String(decoding: units, as: UTF16.self) == "be\u{2060}\u{2060}cause self-\u{2060}aware X- Ray 3- d")
        #expect(units.count == value.utf16.count)
    }

    /// A CR LF line end is one break, both for dehyphenation and for single lines.
    @Test func crlfIsOneLineBreak() {
        let value = "be-\r\ncause"
        let (flat, lineBreaks) = PDFReadableElement.flattened(value)
        var units = Array(flat.utf16)
        PDFReadableElement.dehyphenate(&units, lineBreaks: lineBreaks) { $0 == "because" }
        #expect(String(decoding: units, as: UTF16.self) == "be\u{2060}\u{2060}\u{2060}cause")
        #expect(!Info(text: "One\r\nTwo").isSingleLine)
        #expect(Info(text: "One").isSingleLine)
    }

    /// PDFKit's report keeps line breaks and hyphens where our text has spaces and word joiners.
    @Test func userSelectionEndsWhereItsTextDoes() {
        let text = "Intro. A sen\u{2060}\u{2060}tence runs on. Next one."
        let report = "A sen-\ntence runs\non."
        #expect(PDFReadableElement.end(of: report, in: text, from: 7) == 28)
        #expect(PDFReadableElement.end(of: "😀 b", in: "x 😀 b c", from: 2) == 6)
        #expect(PDFReadableElement.end(of: "longer than the text", in: text, from: 30) == text.utf16.count)
        #expect(PDFReadableElement.end(of: "\n", in: text, from: 7) == 7)
    }

    @Test(
        arguments: [
            ("ends mid", true), ("ends here.", false), ("asks?\n", false), ("quoted.”", false), ("so:", false),
            ("a list;", true), ("hyphen-", true), ("", false), ("(closed.) ", false),
        ] as [(String, Bool)])
    func endsMidSentence(text: String, expected: Bool) {
        #expect(PDFReadableElement.endsMidSentence(text) == expected)
    }

    @Test func joinRules() {
        let join = { (a: Info, b: Info) in PDFReadableElement.join(a, b, isWord: { $0 == "because" }) }
        #expect(join(Info(text: "as he"), Info(text: "read, he")) == .space)
        #expect(join(Info(text: "Ends.\n"), Info(text: "next")) == .none)
        #expect(join(Info(text: "be-"), Info(text: "cause")) == .hyphen(keepsHyphen: false))
        #expect(join(Info(text: "self-"), Info(text: "aware")) == .hyphen(keepsHyphen: true))
        // Font size: about the same joins, clearly different doesn't.
        #expect(join(Info(text: "as he", fontSize: 10), Info(text: "read", fontSize: 10.4)) == .space)
        #expect(join(Info(text: "as he", fontSize: 10), Info(text: "5 a Jer.", fontSize: 8)) == .none)
        #expect(join(Info(text: "Big title", fontSize: 24), Info(text: "body", fontSize: 12)) == .none)
        // Headings: in an AXHeading, or one title-case line before a capital (an inline title-case run still joins).
        #expect(join(Info(text: "Introduction", isHeading: true), Info(text: "text")) == .none)
        #expect(join(Info(text: "PRESENT CODE — ACTIVITY"), Info(text: "Today you")) == .none)
        #expect(join(Info(text: "Quality of Life Wheel"), Info(text: "where a person")) == .space)
        #expect(join(Info(text: "This is a sample"), Info(text: "Quality of Life Wheel")) == .space)
        // Bold before regular text starting with a capital: a heading; an inline bold run before lowercase isn't.
        #expect(join(Info(text: "A bold heading", isBold: true), Info(text: "Text", isBold: false)) == .none)
        #expect(join(Info(text: "is very important", isBold: true), Info(text: "to know", isBold: false)) == .space)
        #expect(join(Info(text: "all bold", isBold: true), Info(text: "Runs on", isBold: true)) == .space)
        #expect(join(Info(text: "font unknown", isBold: true), Info(text: "Runs on")) == .space)
    }

    /// A title-case line doesn't open a sentence that smaller text after it would be deferred for.
    @Test func runsOn() {
        #expect(PDFReadableElement.runsOn(Info(text: "spake")))
        #expect(!PDFReadableElement.runsOn(Info(text: "The First Book of Nephi")))
        #expect(!PDFReadableElement.runsOn(Info(text: "Chapter", isHeading: true)))
    }

    /// Small print ending the page, from the first leaf starting with a mark.
    @Test func footnotesAreMarkedSmallPrintEndingThePage() {
        let page: [(fontSize: CGFloat?, length: Int, isMarked: Bool)] = [(10, 900), (10, 20), (8, 300), (8, 200)].map { ($0, $1, true) }
        #expect(PDFReadableElement.footnoteStart(page) { _ in true } == 2)
        #expect(PDFReadableElement.footnoteStart(page) { _ in nil } == 2)
        #expect(PDFReadableElement.footnoteStart(page) { $0 == 3 } == 3)  // index 2 in the upper half: not a footnote
        #expect(PDFReadableElement.footnoteStart([(8, 300, true), (8, 200, true)]) { _ in true } == 2)  // all one size: none
        #expect(PDFReadableElement.footnoteStart([(10, 900, false), (nil, 50, true)]) { _ in true } == 2)  // size unknown: kept
        // Unmarked small print (a caption, fine print) is read; a footnote after it isn't, nor its unmarked lines.
        #expect(PDFReadableElement.footnoteStart([(10, 900, false), (8, 50, false)]) { _ in true } == 2)
        #expect(PDFReadableElement.footnoteStart([(10, 900, false), (8, 50, false), (8, 90, true), (8, 40, false)]) { _ in true } == 2)
    }

    /// A rule line before the first footnote ("——————⏎13 Note") isn't read, nor does it hide the mark after it.
    @Test(
        arguments: [
            ("——————\n13 Note", 7), ("——————", 6), ("  ____ \n---\r\n4 Note", 13), ("———\u{2028}a Note", 4), ("⸻⸻\n4 Note", 3),
            ("Text — more", 0), ("-- 3", 0), ("1 Note", 0), ("—— Note", 0),
        ] as [(String, Int)])
    func ruleLines(text: String, expected: Int) {
        #expect(PDFReadableElement.ruleLength(text) == expected)
    }

    /// The middle size, unless the first or last character is the only one like it (a scripture chapter number, a drop cap, a final mark).
    @Test(
        arguments: [
            ([8.1, 9.5, 8.1], 8.1), ([10, 6, 10], 10), ([10, 30, 10], 10), ([6, 10, 10], 10), ([10, 10, 6], 10),
            ([8, nil, nil], 8), ([nil, 9, 9], 9),
        ] as [([CGFloat?], CGFloat?)])
    func bodySize(sizes: [CGFloat?], expected: CGFloat?) {
        #expect(PDFReadableElement.bodySize(sizes) == expected)
    }

    @Test(
        arguments: [
            ("1 A note", true), ("12. Note", true), ("[3] Note", true), ("(4) Note", true), ("a Jer. 5:3", true),
            ("* Note", true), ("†Note", true), ("¹Note", true), ("7", true),
            ("Figure 2: a caption", false), ("A caption", false), ("2024 Acme Inc.", false), ("© 2024", false),
        ] as [(String, Bool)])
    func footnoteStartsWithMark(text: String, expected: Bool) {
        #expect(PDFReadableElement.startsWithMark(text) == expected)
    }

    @Test func footnoteMarksAreShortSuperscriptRuns() {
        let text = "his a heart, word12 here and x7y and big"
        func run(_ location: Int, _ length: Int, _ size: CGFloat) -> PDFReadableElement.FontRun {
            PDFReadableElement.FontRun(range: NSRange(location: location, length: length), fontSize: size)
        }
        let runs = [
            run(0, 4, 10), run(4, 2, 6),  // "a "
            run(6, 11, 10), run(17, 2, 6),  // "12"
            run(19, 10, 10), run(29, 3, 9),  // "x7y" at 90%: not a mark
            run(32, 8, 10),
        ]
        let marks = [NSRange(location: 4, length: 1), NSRange(location: 17, length: 2)]
        #expect(PDFReadableElement.markerRanges(runs, in: text, labels: ["a", "12", "7"]) == marks)
    }

    /// Only marks matching a footnote's label on the page count: an exponent is read, and without footnotes everything is.
    @Test func footnoteMarksMatchPageFootnotes() {
        let text = "x2 and word3 here"
        let runs = [(0, 1, 10), (1, 1, 6), (2, 9, 10), (11, 1, 6), (12, 5, 10)].map { location, length, size in
            PDFReadableElement.FontRun(range: NSRange(location: location, length: length), fontSize: CGFloat(size))
        }
        #expect(PDFReadableElement.markerRanges(runs, in: text, labels: []) == [])
        #expect(PDFReadableElement.markerRanges(runs, in: text, labels: ["2", "3"]).count == 2)
        #expect(PDFReadableElement.markerRanges(runs, in: text, labels: ["3"]) == [NSRange(location: 11, length: 1)])
    }

    /// Scripture footnotes start with the verse number, then the letter the body marks with.
    @Test(
        arguments: [
            ("12. Note", ["12"]), ("[3] Note", ["3"]), ("(4) Note", ["4"]), ("¹Note", ["1"]), ("²³ Note", ["23"]), ("a Jer.", ["a"]),
            ("†Note", ["†"]), ("** Note", ["**"]), ("Note", []), ("19 a tg Example.", ["19", "a"]), ("1 1a Andrus, Ezra.", ["1", "a"]),
            ("1 1 a tg Birthright.", ["1", "a"]),
            ("3 c 1 Ne. 10:8", ["3", "c"]), ("2a Note", ["2", "a"]), ("1 I said", ["1"]), ("12 in. wide", ["12"]),
        ] as [(String, [String])])
    func footnoteLabels(text: String, expected: [String]) {
        #expect(PDFReadableElement.footnoteLabels(ofLine: text) == expected)
    }

    /// Only a long enough selected text counts as one in a footnote it matches.
    @Test(
        arguments: [
            ("The First ", false), ("The note.", false), ("Jerusalemites", false), ("A footnote on page 2.", true),
            ("1 Ne. 10:8 see also", false), ("tg Jerusalem, Bountiful", true),
        ] as [(String, Bool)])
    func distinctiveSelections(text: String, expected: Bool) {
        #expect(PDFReadableElement.isDistinctive(text) == expected)
    }

    @Test(
        arguments: [
            ("12", "ruling.12 Next", true), ("12", "Form 1212", false), ("*", "boxes*", true), ("†", "word† and", true),
            ("12", "ruling12", true), ("1", "the end.¹", true), ("12", "page 12 here", false), ("1", "ruling.12", false),
            ("3", "it,3) here", true), ("*", "5 * 3", false), ("a", "worda here", false),
        ] as [(String, String, Bool)])
    func gluedMarks(label: String, text: String, expected: Bool) {
        #expect(PDFReadableElement.hasGluedMark(label, in: text) == expected)
    }

    @Test func boldFontNames() {
        #expect(PDFReadableElement.isBold(fontName: "Arial-BoldMT"))
        #expect(PDFReadableElement.isBold(fontName: "ABCDEF+Inter-SemiBold"))
        #expect(PDFReadableElement.isBold(fontName: "Arial-Black"))
        #expect(!PDFReadableElement.isBold(fontName: "TimesNewRomanPSMT"))
        #expect(!PDFReadableElement.isBold(fontName: "Helvetica-Oblique"))
    }

    @Test func marginIsTopAndBottomOfPage() {
        let page = CGRect(x: 0, y: 1000, width: 600, height: 800)
        #expect(PDFReadableElement.isInMargin(CGRect(x: 50, y: 1020, width: 100, height: 20), of: page))
        #expect(PDFReadableElement.isInMargin(CGRect(x: 50, y: 1760, width: 100, height: 20), of: page))
        #expect(!PDFReadableElement.isInMargin(CGRect(x: 50, y: 1100, width: 100, height: 20), of: page))
        #expect(!PDFReadableElement.isInMargin(.zero, of: page))
    }

    @Test func marginKeysMatchAcrossPageNumbers() {
        let key = PDFReadableElement.marginKey
        #expect(key("Page 3 of 9") == key("Page 4 of 9"))
        #expect(key("- 12 -") == key("- 13 -"))
        #expect(key("xii") == key("XIII"))
        #expect(key("Chapter  One ") == key("chapter one"))
        #expect(key("Running Title") != key("Another Title"))
        // Words of numeral letters aren't numerals.
        #expect(key("did 3") != key("dim 3"))
        #expect(key("Civil Law") == "civil law")
        #expect(key("Part iv") == key("Part xii"))
    }

    /// A footnote label alone in a leaf is a body mark only in small type or of unknown size (a stray page number isn't).
    @Test func markLeafIsSmall() {
        let labels: Set = ["5"]
        #expect(PDFReadableElement.isMarkLeaf(" 5 ", size: 8, bodySize: 14, labels: labels))
        #expect(PDFReadableElement.isMarkLeaf("5", size: nil, bodySize: 14, labels: labels))
        #expect(!PDFReadableElement.isMarkLeaf("5", size: 14, bodySize: 14, labels: labels))
        #expect(!PDFReadableElement.isMarkLeaf("6", size: 8, bodySize: 14, labels: labels))
    }

    /// Leaves are found in order, each a little after the previous one; ones not there (or empty) are nil.
    @Test func leafStartsInPageText() {
        let text = "Title\nThe first has bold words.\n3 A mark\u{2060}a splits it."
        let starts = PDFReadableElement.starts(of: ["Title", "", "The first has", "bold words.", "A mark", "missing", "a", "splits it."], in: text)
        #expect(starts == [0, nil, 6, 20, 34, nil, 41, 43])
    }

    /// Sizes within 0.05 pt count as one (the last one seen); runs without a size are left out.
    @Test(
        arguments: [
            ([(10, 5), (8, 20), (nil, 100), (10, 10)], 8), ([(10, 5), (10.04, 5), (8, 8)], 10.04), ([(nil, 4)], nil), ([], nil),
        ] as [([(CGFloat?, Int)], CGFloat?)])
    func dominantSize(runs: [(CGFloat?, Int)], expected: CGFloat?) {
        #expect(PDFReadableElement.dominantSize(runs.map { (fontSize: $0, length: $1) }) == expected)
    }

    @Test(
        arguments: [
            ("PRESENT CODE — ACTIVITY", true), ("Quality of Life", true), ("Chapter one", true), ("Notes on this page", false),
            ("Big Cat", false), ("1234", false), ("", false),
        ] as [(String, Bool)])
    func titleCase(text: String, expected: Bool) {
        #expect(PDFReadableElement.isTitleCase(text) == expected)
    }

    @Test(
        arguments: [
            (8, 10, true), (8.99, 10, true), (9, 10, false), (12, 10, false), (nil, 10, false), (8, nil, false),
        ] as [(CGFloat?, CGFloat?, Bool)])
    func smaller(size: CGFloat?, other: CGFloat?, expected: Bool) {
        #expect(PDFReadableElement.isSmaller(size, than: other) == expected)
    }

    /// Whitespace, hyphens, word joiners and soft hyphens are ignored; dashes aren't.
    @Test func comparableDropsLayoutCharacters() {
        #expect(PDFReadableElement.comparable("A sen-\ntence  runs\u{2060}\u{AD}on. ") == "Asentencerunson.")
        #expect(PDFReadableElement.comparable("a – b — c") == "a–b—c")
        #expect(PDFReadableElement.comparable("😀 x") == "😀x")
    }

    @Test(
        arguments: [
            ("  [12] Note", "12"), ("(4) Note", "4"), ("¹²Note", "12"), ("٣ Note", "3"), ("*†Note", "*†"), ("a Jer.", "a"),
            ("Note", nil), ("", nil),
        ] as [(String, String?)])
    func footnoteLabel(text: String, expected: String?) {
        #expect(PDFReadableElement.footnoteLabel(text) == expected)
    }
}
