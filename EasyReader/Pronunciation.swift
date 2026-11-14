import AVFoundation
import Defaults
import Foundation

/// A user rule that changes how matching text is spoken: replaced by other text, or spoken from IPA.
struct Pronunciation: Identifiable, Hashable, Codable, Defaults.Serializable {
    let id: UUID
    var search: String
    /// Text spoken instead (a regex template with `$1` etc. when `isRegex`), or IPA when `isPhonetic`.
    var replace: String
    /// Bundle ID of the app the rule is limited to; `nil` = all apps.
    var appDomain: String?
    var ignoreCase: Bool
    /// A match edge that's a word character can't touch another one; non-word edges (e.g. `:-)`) match anywhere.
    var wholeWord: Bool
    var isRegex: Bool
    /// `replace` is IPA: the original text stays, spoken as that IPA.
    var isPhonetic: Bool
    var enabled: Bool

    init(
        search: String,
        replace: String,
        appDomain: String? = nil,
        ignoreCase: Bool = true,
        wholeWord: Bool = true,
        isRegex: Bool = false,
        isPhonetic: Bool = false,
        enabled: Bool = true
    ) {
        id = UUID()
        self.search = search
        self.replace = replace
        self.appDomain = appDomain
        self.ignoreCase = ignoreCase
        self.wholeWord = wholeWord
        self.isRegex = isRegex
        self.isPhonetic = isPhonetic
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, search, replace, appDomain, ignoreCase, wholeWord, isRegex, isPhonetic, enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        search = try container.decode(String.self, forKey: .search)
        replace = try container.decode(String.self, forKey: .replace)
        appDomain = try container.decodeIfPresent(String.self, forKey: .appDomain)
        ignoreCase = try container.decodeIfPresent(Bool.self, forKey: .ignoreCase) ?? true
        // Legacy rules matched anywhere.
        wholeWord = try container.decodeIfPresent(Bool.self, forKey: .wholeWord) ?? false
        isRegex = try container.decodeIfPresent(Bool.self, forKey: .isRegex) ?? false
        isPhonetic = try container.decodeIfPresent(Bool.self, forKey: .isPhonetic) ?? false
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    func regularExpression() throws -> NSRegularExpression {
        try NSRegularExpression(
            pattern: isRegex ? search : NSRegularExpression.escapedPattern(for: search),
            options: ignoreCase ? [.caseInsensitive] : []
        )
    }

    fileprivate func isAllowedMatch(_ range: NSRange, in text: NSString) -> Bool {
        guard wholeWord else { return true }
        func isWordCharacter(at index: Int) -> Bool {
            guard index >= 0, index < text.length else { return false }
            let character = text.rangeOfComposedCharacterSequence(at: index)
            return text.substring(with: character).unicodeScalars.contains {
                CharacterSet.alphanumerics.contains($0) || $0 == "_"
            }
        }
        if isWordCharacter(at: range.location), isWordCharacter(at: range.location - 1) { return false }
        if isWordCharacter(at: range.upperBound - 1), isWordCharacter(at: range.upperBound) { return false }
        return true
    }
}

/// Text after applying pronunciations, with a map back to the original text (UTF-16 offsets).
struct SpokenText: Equatable {
    struct Segment: Equatable {
        var original: NSRange
        /// For phonetic rules the original text, spoken as `ipa`.
        var spoken: NSRange
        var ipa: String?
    }

    let original: String
    let text: String
    /// Replaced ranges, in order, non-overlapping.
    let segments: [Segment]

    private typealias Candidate = (range: NSRange, rule: Int, replacement: String, ipa: String?)

    /// One pass: overlaps go to the earliest, then longest match, then an app-specific rule, then list order; replacements aren't matched again.
    init(_ original: String, applying rules: [Pronunciation]) {
        self.original = original
        let source = original as NSString
        let text = NSMutableString()
        var segments: [Segment] = []
        var cursor = 0
        for candidate in Self.candidates(in: original, applying: rules) where candidate.range.location >= cursor {
            text.append(source.substring(with: NSRange(location: cursor, length: candidate.range.location - cursor)))
            let spoken = NSRange(location: text.length, length: (candidate.replacement as NSString).length)
            text.append(candidate.replacement)
            segments.append(Segment(original: candidate.range, spoken: spoken, ipa: candidate.ipa))
            cursor = candidate.range.upperBound
        }
        text.append(source.substring(from: cursor))
        self.text = text as String
        self.segments = segments
    }

    /// All matches of all rules, sorted by priority.
    private static func candidates(in original: String, applying rules: [Pronunciation]) -> [Candidate] {
        let source = original as NSString
        let all = NSRange(location: 0, length: source.length)
        var candidates: [Candidate] = []
        for (index, rule) in rules.enumerated() where !rule.search.isEmpty {
            guard let regex = try? rule.regularExpression() else { continue }
            for match in regex.matches(in: original, range: all)
            where match.range.length > 0 && rule.isAllowedMatch(match.range, in: source) {
                let replacement =
                    rule.isRegex
                    ? regex.replacementString(for: match, in: original, offset: 0, template: rule.replace)
                    : rule.replace
                if rule.isPhonetic {
                    guard !replacement.isEmpty else { continue }
                    candidates.append((match.range, index, source.substring(with: match.range), replacement))
                } else {
                    candidates.append((match.range, index, replacement, nil))
                }
            }
        }
        func generality(_ rule: Int) -> Int { rules[rule].appDomain == nil ? 1 : 0 }
        candidates.sort {
            ($0.range.location, -$0.range.length, generality($0.rule), $0.rule)
                < ($1.range.location, -$1.range.length, generality($1.rule), $1.rule)
        }
        return candidates
    }

    /// The original offset of a spoken offset; inside a replacement, the start of what it replaced.
    func originalOffset(forSpoken offset: Int) -> Int {
        var delta = 0
        for segment in segments {
            if offset < segment.spoken.location { break }
            if offset < segment.spoken.upperBound { return segment.original.location }
            delta = segment.original.upperBound - segment.spoken.upperBound
        }
        return offset + delta
    }

    var attributedText: NSAttributedString {
        let attributed = NSMutableAttributedString(string: text)
        for segment in segments {
            guard let ipa = segment.ipa else { continue }
            attributed.addAttribute(
                NSAttributedString.Key(AVSpeechSynthesisIPANotationAttribute),
                value: ipa,
                range: segment.spoken
            )
        }
        return attributed
    }

    var hasPhonetics: Bool { segments.contains { $0.ipa != nil } }
}

// MARK: - VoiceOver import

extension Pronunciation {
    /// VoiceOver Utility › Speech › Pronunciation; `nil` if its preferences can't be read.
    static func voiceOverPronunciations() -> [Pronunciation]? {
        let domain =
            UserDefaults.standard.persistentDomain(forName: "com.apple.VoiceOver4/default")
            ?? NSDictionary(
                contentsOf: FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Preferences/com.apple.VoiceOver4/default.plist")
            ) as? [String: Any]
        guard let domain else { return nil }
        let bundle = Bundle(path: "/System/Library/PrivateFrameworks/ScreenReader.framework")
        return voiceOverPronunciations(from: domain) { key in
            let value = bundle?.localizedString(forKey: key, value: nil, table: "SCROutputDefaultUserSubstitutions")
            return value == key ? nil : value
        }
    }

    /// `SCRSubText` is user-entered, `SCRSubTextKey` a built-in default (localized by `localize`).
    static func voiceOverPronunciations(
        from preferences: [String: Any],
        localize: (String) -> String?
    ) -> [Pronunciation] {
        // Strings ("0"/"1") until changed in VoiceOver Utility, then booleans.
        func flag(_ value: Any?) -> Bool {
            if let bool = value as? Bool { return bool }
            if let string = value as? String { return string != "0" }
            return true
        }
        return preferences.keys.sorted().compactMap { key in
            guard key.hasPrefix("custom.pronunciation."),
                let entry = preferences[key] as? [String: Any],
                let search = entry["SCRSearchText"] as? String, !search.isEmpty,
                let replace = (entry["SCRSubText"] as? String) ?? (entry["SCRSubTextKey"] as? String).flatMap(localize)
            else { return nil }
            let domain = entry["SCRDomainIdentifier"] as? String
            return Pronunciation(
                search: search,
                replace: replace.trimmingCharacters(in: .whitespaces),
                appDomain: domain == "SCRAnyApplication" ? nil : domain,
                ignoreCase: flag(entry["SCRIgnoreCase"]),
                enabled: flag(entry["SCREnabled"])
            )
        }
    }

    /// Same search (text, app, case, regex), whatever the replacement.
    func matchesRule(of other: Pronunciation) -> Bool {
        search == other.search && appDomain == other.appDomain && ignoreCase == other.ignoreCase
            && isRegex == other.isRegex
    }
}
