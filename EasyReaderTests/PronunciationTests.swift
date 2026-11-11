import AVFoundation
import Foundation
import Testing

@testable import EasyReader

struct PronunciationTests {
    @Test func codableRoundTrip() throws {
        let pronunciation = Pronunciation(
            search: "GUI", replace: "gooey", domain: "com.apple.TextEdit", ignoreCase: false, wholeWord: false,
            isRegex: true, isPhonetic: true, enabled: false
        )
        let data = try JSONEncoder().encode(pronunciation)
        #expect(try JSONDecoder().decode(Pronunciation.self, from: data) == pronunciation)
    }

    /// Rules saved before `wholeWord`/`isRegex`/`isPhonetic` existed decode, keeping their old match-anywhere behavior.
    @Test func decodesLegacyRule() throws {
        let json = #"{"id":"0F3B1C52-7A1E-4D43-9C1A-2B6F2C0E8D11","search":"GUI","replace":"gooey","ignoreCase":false,"enabled":true}"#
        let rule = try JSONDecoder().decode(Pronunciation.self, from: Data(json.utf8))
        #expect(rule.search == "GUI" && rule.replace == "gooey" && rule.domain == nil)
        #expect(!rule.ignoreCase && rule.enabled)
        #expect(!rule.wholeWord && !rule.isRegex && !rule.isPhonetic)
    }

    @Test func uniqueIDs() {
        let a = Pronunciation(search: "x", replace: "y", ignoreCase: true, enabled: true)
        let b = Pronunciation(search: "x", replace: "y", ignoreCase: true, enabled: true)
        #expect(a.id != b.id)
    }

    private func spoken(_ text: String, _ rules: Pronunciation...) -> String {
        SpokenText(text, applying: rules).text
    }

    @Test func noRulesKeepsText() {
        let result = SpokenText("Hello, world.", applying: [])
        #expect(result.text == "Hello, world.")
        #expect(result.segments.isEmpty)
        #expect(result.originalOffset(forSpoken: 7) == 7)
    }

    @Test func wholeWordSkipsMatchesInsideWords() {
        let rule = Pronunciation(search: "GUI", replace: "gooey", ignoreCase: false)
        #expect(spoken("A GUI, GUIDE, aGUI, GUI_x, GUI2 and GUI.", rule) == "A gooey, GUIDE, aGUI, GUI_x, GUI2 and gooey.")
    }

    @Test func matchAnywhereWithoutWholeWord() {
        let rule = Pronunciation(search: "GUI", replace: "gooey", ignoreCase: false, wholeWord: false)
        #expect(spoken("GUIDE", rule) == "gooeyDE")
    }

    /// Edges that aren't word characters match next to anything.
    @Test func wholeWordWithSymbolEdges() {
        let rule = Pronunciation(search: ":-)", replace: "smiley")
        #expect(spoken("hi:-)there", rule) == "hismileythere")
        let cpp = Pronunciation(search: "C++", replace: "C plus plus", ignoreCase: false)
        #expect(spoken("C++ and C++, not AC++", cpp) == "C plus plus and C plus plus, not AC++")
    }

    @Test func wholeWordCountsNonASCIILetters() {
        let rule = Pronunciation(search: "cafe", replace: "kafay")
        #expect(spoken("cafe caféx écafe", rule) == "kafay caféx écafe")
    }

    @Test(arguments: [(true, "a gooey, a gooey, a gooey"), (false, "a gooey, a Gui, a gui")] as [(Bool, String)])
    func ignoreCase(ignoreCase: Bool, expected: String) {
        let rule = Pronunciation(search: "GUI", replace: "gooey", ignoreCase: ignoreCase)
        #expect(spoken("a GUI, a Gui, a gui", rule) == expected)
    }

    /// A replacement is never matched again by a later rule.
    @Test func replacementsDontChain() {
        let first = Pronunciation(search: "a", replace: "b")
        let second = Pronunciation(search: "b", replace: "c")
        #expect(spoken("a b", first, second) == "b c")
    }

    @Test func longestMatchWins() {
        let short = Pronunciation(search: "New", replace: "noo")
        let long = Pronunciation(search: "New York", replace: "big apple")
        #expect(spoken("New York is New", short, long) == "big apple is noo")
    }

    /// An earlier match wins over a longer one starting later, whatever the list order.
    @Test func earliestMatchWins() {
        let later = Pronunciation(search: "York City", replace: "NYC")
        let earlier = Pronunciation(search: "New York", replace: "big apple")
        #expect(spoken("New York City", later, earlier) == "big apple City")
    }

    @Test func firstRuleWinsTies() {
        let first = Pronunciation(search: "tomato", replace: "tomahto")
        let second = Pronunciation(search: "tomato", replace: "tomayto")
        #expect(spoken("tomato", first, second) == "tomahto")
    }

    /// For the same match, a rule limited to an app beats one for all apps, wherever it is in the list.
    @Test func appSpecificRuleWinsTies() {
        let all = Pronunciation(search: "tomato", replace: "tomayto")
        let safari = Pronunciation(search: "tomato", replace: "tomahto", domain: "com.apple.Safari")
        #expect(spoken("tomato", all, safari) == "tomahto")
        #expect(spoken("tomato", safari, all) == "tomahto")
        // Longer matches still win first.
        let phrase = Pronunciation(search: "tomato soup", replace: "soup")
        #expect(spoken("tomato soup", safari, phrase) == "soup")
    }

    @Test func emptyReplacementRemovesText() {
        let rule = Pronunciation(search: "[citation needed]", replace: "")
        #expect(spoken("True[citation needed].", rule) == "True.")
    }

    @Test func emptySearchIsIgnored() {
        #expect(spoken("abc", Pronunciation(search: "", replace: "x")) == "abc")
    }

    /// Literal rules treat regex syntax in the search and `$` in the replacement literally.
    @Test func literalRuleEscapesSyntax() {
        let rule = Pronunciation(search: "a.b", replace: "$0 cost", wholeWord: false)
        #expect(spoken("a.b axb", rule) == "$0 cost axb")
    }

    @Test func regexWithTemplate() {
        let rule = Pronunciation(search: #"(\d+)\s?km"#, replace: "$1 kilometers", isRegex: true)
        #expect(spoken("Run 5km, then 10 km.", rule) == "Run 5 kilometers, then 10 kilometers.")
    }

    @Test(arguments: [(true, "kuhler, kuhler, colors"), (false, "Color, COLOUR, colors")] as [(Bool, String)])
    func regexWithIgnoreCaseAndWholeWord(ignoreCase: Bool, expected: String) {
        let rule = Pronunciation(search: "colou?r", replace: "kuhler", ignoreCase: ignoreCase, isRegex: true)
        #expect(spoken("Color, COLOUR, colors", rule) == expected)
    }

    @Test func invalidRegexIsIgnored() {
        let rule = Pronunciation(search: "(", replace: "x", isRegex: true)
        #expect((try? rule.regularExpression()) == nil)
        #expect(spoken("a ( b", rule) == "a ( b")
    }

    /// Phonetic rules keep the original text and attach IPA to it.
    @Test func phoneticRuleAddsIPAAttribute() throws {
        let rule = Pronunciation(search: "tomato", replace: "təˈmɑːtəʊ", isPhonetic: true)
        let result = SpokenText("A tomato, a Tomato.", applying: [rule])
        #expect(result.text == "A tomato, a Tomato.")
        #expect(result.hasPhonetics)
        let key = NSAttributedString.Key(AVSpeechSynthesisIPANotationAttribute)
        let attributed = result.attributedText
        var effective = NSRange()
        #expect(attributed.attribute(key, at: 2, effectiveRange: &effective) as? String == "təˈmɑːtəʊ")
        #expect(effective == NSRange(location: 2, length: 6))
        #expect(attributed.attribute(key, at: 12, effectiveRange: nil) as? String == "təˈmɑːtəʊ")
        #expect(attributed.attribute(key, at: 0, effectiveRange: nil) == nil)
    }

    /// The IPA range is in the spoken text, shifted by an earlier replacement of another length.
    @Test func phoneticRangeAfterLongerReplacement() {
        let rules = [Pronunciation(search: "GUI", replace: "gooey"), Pronunciation(search: "tomato", replace: "təˈmɑːtəʊ", isPhonetic: true)]
        let result = SpokenText("GUI tomato", applying: rules)
        #expect(result.text == "gooey tomato")
        var effective = NSRange()
        let key = NSAttributedString.Key(AVSpeechSynthesisIPANotationAttribute)
        #expect(result.attributedText.attribute(key, at: 6, effectiveRange: &effective) as? String == "təˈmɑːtəʊ")
        #expect(effective == NSRange(location: 6, length: 6))
        #expect(result.originalOffset(forSpoken: 6) == 4)
    }

    @Test func phoneticRuleWithEmptyIPAIsIgnored() {
        let result = SpokenText("tomato", applying: [Pronunciation(search: "tomato", replace: "", isPhonetic: true)])
        #expect(!result.hasPhonetics)
        #expect(result.segments.isEmpty)
    }

    /// Spoken offsets map back to the original: shifted after a replacement, its start inside one.
    @Test func originalOffsetMapping() {
        // "I like GUI apps and qty." → "I like gooey apps and quantity."
        let rules = [Pronunciation(search: "GUI", replace: "gooey"), Pronunciation(search: "qty", replace: "quantity")]
        let result = SpokenText("I like GUI apps and qty.", applying: rules)
        #expect(result.text == "I like gooey apps and quantity.")
        #expect(result.originalOffset(forSpoken: 0) == 0)
        #expect(result.originalOffset(forSpoken: 7) == 7)  // "gooey" → "GUI"
        #expect(result.originalOffset(forSpoken: 10) == 7)  // inside "gooey"
        #expect(result.originalOffset(forSpoken: 13) == 11)  // "apps"
        #expect(result.originalOffset(forSpoken: 22) == 20)  // "quantity" → "qty"
        #expect(result.originalOffset(forSpoken: 30) == 23)  // "."
        #expect(result.originalOffset(forSpoken: 31) == 24)  // end
    }

    @Test func originalOffsetAfterShorterReplacement() {
        let result = SpokenText("Hello there world", applying: [Pronunciation(search: "there", replace: "")])
        #expect(result.text == "Hello  world")
        #expect(result.originalOffset(forSpoken: 7) == 12)
    }

    @Test func voiceOverImport() {
        let preferences: [String: Any] = [
            "custom.pronunciation.2": [
                "SCRDomainIdentifier": "SCRAnyApplication", "SCREnabled": "1", "SCRIgnoreCase": "0",
                "SCRSearchText": "GUI", "SCRSubTextKey": "SCRUserSubstitution.GUI",
            ],
            "custom.pronunciation.1": [
                "SCRDomainIdentifier": "com.apple.TextEdit", "SCREnabled": false, "SCRIgnoreCase": true,
                "SCRSearchText": "brb", "SCRSubText": " be right back ",
            ],
            "custom.pronunciation.3": ["SCRSearchText": "x", "SCRSubTextKey": "SCRUserSubstitution.unknown"],
            "custom.pronunciation.4": ["SCRSubText": "no search"],
            "SCRSomethingElse": ["SCRSearchText": "a", "SCRSubText": "b"],
        ]
        let rules = Pronunciation.voiceOverPronunciations(from: preferences) { key in
            key == "SCRUserSubstitution.GUI" ? "gooey" : nil
        }
        #expect(rules.count == 2)
        let brb = rules[0]
        #expect(brb.search == "brb" && brb.replace == "be right back" && brb.domain == "com.apple.TextEdit")
        #expect(brb.ignoreCase && !brb.enabled && brb.wholeWord)
        let gui = rules[1]
        #expect(gui.search == "GUI" && gui.replace == "gooey" && gui.domain == nil)
        #expect(!gui.ignoreCase && gui.enabled)
    }

    @Test func matchesRuleIgnoresIDAndReplacement() {
        let a = Pronunciation(search: "GUI", replace: "gooey")
        var b = Pronunciation(search: "GUI", replace: "goo-ee")
        #expect(a.matchesRule(of: b))
        b.domain = "com.example"
        #expect(!a.matchesRule(of: b))
    }
}
