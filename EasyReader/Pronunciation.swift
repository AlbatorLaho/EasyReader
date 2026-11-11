//
//  Pronunciation.swift
//  EasyReader
//
//  Created by Ewalk on 24/12/22.
//

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
    // TODO: rename to appDomain?
    var domain: String?
    var ignoreCase = true
    /// Don't match inside words: a match that starts (ends) with a letter, digit, or `_` can't follow
    /// (precede) another one. Edges that aren't word characters (e.g. `:-)`) match anywhere.
    var wholeWord = true
    /// `search` is an `NSRegularExpression` pattern.
    var isRegex = false
    /// `replace` is IPA (`AVSpeechSynthesisIPANotationAttribute`): the original text stays, spoken as IPA.
    var isPhonetic = false
    var enabled = true

    init(
        search: String,
        replace: String,
        domain: String? = nil,
        ignoreCase: Bool = true,
        wholeWord: Bool = true,
        isRegex: Bool = false,
        isPhonetic: Bool = false,
        enabled: Bool = true
    ) {
        self.id = UUID()
        self.search = search
        self.replace = replace
        self.domain = domain
        self.ignoreCase = ignoreCase
        self.wholeWord = wholeWord
        self.isRegex = isRegex
        self.isPhonetic = isPhonetic
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, search, replace, domain, ignoreCase, wholeWord, isRegex, isPhonetic, enabled
    }

    /// Keys added after the first release are optional, so older saved rules still decode.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        search = try container.decode(String.self, forKey: .search)
        replace = try container.decode(String.self, forKey: .replace)
        domain = try container.decodeIfPresent(String.self, forKey: .domain)
        ignoreCase = try container.decodeIfPresent(Bool.self, forKey: .ignoreCase) ?? true
        // Rules saved before `wholeWord` existed matched anywhere.
        wholeWord = try container.decodeIfPresent(Bool.self, forKey: .wholeWord) ?? false
        isRegex = try container.decodeIfPresent(Bool.self, forKey: .isRegex) ?? false
        isPhonetic = try container.decodeIfPresent(Bool.self, forKey: .isPhonetic) ?? false
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    var options: String.CompareOptions {
        ignoreCase ? [.caseInsensitive] : []
    }

    /// The compiled search; throws for an invalid pattern (only possible when `isRegex`).
    func regularExpression() throws -> NSRegularExpression {
        try NSRegularExpression(
            pattern: isRegex ? search : NSRegularExpression.escapedPattern(for: search),
            options: ignoreCase ? [.caseInsensitive] : []
        )
    }

    /// Whether `range` of `text` passes the `wholeWord` check.
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
        /// Matched range in the original text.
        var original: NSRange
        /// Its replacement's range in `text` (for phonetic rules the same text, just spoken as `ipa`).
        var spoken: NSRange
        var ipa: String?
    }

    let original: String
    let text: String
    /// Replaced ranges, in order, non-overlapping.
    let segments: [Segment]

    /// Applies `rules` in one pass: overlapping matches resolve to the earliest, then the longest,
    /// then a rule limited to an app over one for all apps, then the first rule. Replacements are never matched again (no chaining). Invalid regexes and
    /// empty matches are ignored.
    init(_ original: String, applying rules: [Pronunciation]) {
        self.original = original
        let source = original as NSString
        let all = NSRange(location: 0, length: source.length)
        var candidates: [(range: NSRange, rule: Int, replacement: String, ipa: String?)] = []
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
        func generality(_ rule: Int) -> Int { rules[rule].domain == nil ? 1 : 0 }
        candidates.sort {
            ($0.range.location, -$0.range.length, generality($0.rule), $0.rule)
                < ($1.range.location, -$1.range.length, generality($1.rule), $1.rule)
        }

        let text = NSMutableString()
        var segments: [Segment] = []
        var cursor = 0
        for candidate in candidates where candidate.range.location >= cursor {
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

    /// `text`, with IPA attributes on phonetic segments.
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
    /// VoiceOver's custom pronunciations (VoiceOver Utility › Speech › Pronunciation), or `nil` if its
    /// preferences can't be read.
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

    /// Parses VoiceOver preferences: `custom.pronunciation.*` dictionaries with `SCRSearchText` and either
    /// `SCRSubText` (user-entered) or `SCRSubTextKey` (built-in default, localized by `localize`).
    /// Flags are strings (`"0"`/`"1"`) until changed in VoiceOver Utility, then booleans.
    static func voiceOverPronunciations(
        from preferences: [String: Any],
        localize: (String) -> String?
    ) -> [Pronunciation] {
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
                domain: domain == "SCRAnyApplication" ? nil : domain,
                ignoreCase: flag(entry["SCRIgnoreCase"]),
                enabled: flag(entry["SCREnabled"])
            )
        }
    }

    /// Whether `other` is the same rule apart from its ID and enabled state.
    func matchesRule(of other: Pronunciation) -> Bool {
        search == other.search && domain == other.domain && ignoreCase == other.ignoreCase
            && isRegex == other.isRegex
    }
}
