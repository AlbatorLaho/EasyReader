import Testing

@testable import EasyReader

struct WebAreaReadableElementLogicTests {
    @Test(
        arguments: [
            ("bold", 10, Selection(8..<12)),  // two past: snaps back
            ("bold", 8, Selection(8..<12)),  // exact
            ("bold", 6, Selection(8..<12)),  // two before
            ("nope", 8, Selection(8..<12)),  // not found: kept as measured
            ("", 3, Selection(3..<3)),
            ("text", 30, Selection(13..<17)),  // past the end (text shrank): found near the end
            ("bold", 30, Selection(17..<17)),  // past the end, not found: at the end
            ("", 30, Selection(17..<17)),
        ] as [(String, Int, Selection)])
    func locatesNearestOccurrence(string: String, offset: Int, expected: Selection) {
        #expect(WebAreaReadableElement.locate(string, near: offset, in: "Second  bold text", tolerance: 4) == expected)
    }

    @Test func locatesWithoutTolerance() {
        #expect(WebAreaReadableElement.locate("bold", near: 10, in: "Second  bold text", tolerance: 0) == Selection(10..<14))
    }
    /// A marker measured from an anchor: the text between them sits right after or before the anchor.
    @Test(
        arguments: [
            ("lo w", 3, 3, 7),  // after
            ("lo w", 7, 7, 3),  // before
            ("", 5, 5, 5),  // same position
            ("l", 3, 9, 4),  // both sides match ("hel|lo"): closer to the hint
            ("l", 3, 0, 2),
            ("xyz", 4, 4, nil),  // other text
        ] as [(String, Int, Int, Int?)])
    func measuresFromAnchor(between: String, anchor: Int, hint: Int, expected: Int?) {
        #expect(WebAreaReadableElement.offset(of: between, beside: anchor, in: "hello world", near: hint) == expected)
    }

    @Test func nearestOccurrence() {
        let text = "ab ab ab"
        #expect(WebAreaReadableElement.nearestOccurrence(of: "ab", to: 4, in: text) == 3)
        #expect(WebAreaReadableElement.nearestOccurrence(of: "ab", to: 0, in: text) == 0)
        #expect(WebAreaReadableElement.nearestOccurrence(of: "ab", to: 8, in: text) == 6)
        #expect(WebAreaReadableElement.nearestOccurrence(of: "cd", to: 4, in: text) == nil)
    }

    /// Marker ranges can miss text outside leaves but never add any; whitespace around either is ignored.
    @Test(
        arguments: [
            ("A sentence. ^", "A sentence.", true), (" Same ", "Same", true), ("Unit text", "Unit text and more", false),
            ("Unit text", "", false), ("", "", true), ("Unit", "Other", false),
        ] as [(String, String, Bool)])
    func covers(expected: String, selected: String, result: Bool) {
        #expect(WebAreaReadableElement.covers(expected, selected) == result)
    }

    typealias Report = WebAreaReadableElement.Report

    private let tracked = Report(selection: Selection(100..<120), string: "The tracked unit is.")

    /// A known report or the tracked unit, by text within 64 chars of where it was; else overlapping the unit.
    @Test(
        arguments: [
            (Report(selection: Selection(10..<14), string: "word"), true),  // the baseline
            (Report(selection: Selection(74..<78), string: "word"), true),  // the baseline, 64 chars on
            (Report(selection: Selection(75..<79), string: "word"), false),  // 65 chars on: the user's
            (Report(selection: Selection(150..<170), string: "The tracked unit is."), true),  // shifted page text
            (Report(selection: Selection(190..<210), string: "The tracked unit is."), false),
            (Report(selection: Selection(119..<130), string: "Next words."), true),  // overlapping
            (Report(selection: Selection(120..<130), string: "Next words."), false),  // adjacent
            (Report(selection: Selection(10..<14), string: "else"), false),
        ] as [(Report, Bool)])
    func reportIsUnchanged(reported: Report, expected: Bool) {
        let baseline = Report(selection: Selection(10..<14), string: "word")
        #expect(WebAreaReadableElement.isUnchanged(reported, known: [baseline], tracked: tracked) == expected)
    }

    /// The user selecting inside the unit being read isn't noticed (known issue).
    @Test func userSelectionInsideTrackedUnitIsIgnored() {
        let user = Report(selection: Selection(104..<111), string: "tracked")
        withKnownIssue {
            #expect(!WebAreaReadableElement.isUnchanged(user, known: [], tracked: tracked))
        }
    }
}
