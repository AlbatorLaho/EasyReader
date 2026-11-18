import NaturalLanguage

final class NLTextSelector: TextSelector {
    private let tagger = NLTagger(tagSchemes: [.lexicalClass])
    private let taggerUnit: NLTokenUnit

    init(unit: Selection.Unit) {
        switch unit {
            case .sentence: taggerUnit = .sentence
            case .paragraph: taggerUnit = .paragraph
        }
    }

    func select(_ direction: Selection.Direction, from selection: Selection, in string: String) -> Selection {
        tagger.string = string
        let startIndex: String.Index
        let endIndex: String.Index
        switch direction {
            case .forward:
                startIndex = selection.endIndex(in: string)
                var tagRange: Range<String.Index>?
                tagger.enumerateTags(in: startIndex..<string.endIndex, unit: taggerUnit, scheme: .lexicalClass) { tag, range in
                    guard tag != .paragraphBreak else { return true }
                    tagRange = range
                    return false
                }
                endIndex = tagRange.map { Self.skippingCitations(from: $0.upperBound, in: string) } ?? string.endIndex
            case .backward:
                endIndex = selection.startIndex(in: string)
                var tagStart: String.Index?
                tagger.enumerateTagsReversed(in: string.startIndex..<endIndex, unit: taggerUnit, scheme: .lexicalClass) { tag, range in
                    guard tag != .paragraphBreak else { return true }
                    let start = Self.skippingCitations(from: range.lowerBound, in: string)
                    // Only a citation's tail ("2] ") between the two boundaries: belongs to the unit before
                    guard start < endIndex else { return true }
                    tagStart = start
                    return false
                }
                startIndex = tagStart ?? string.startIndex
        }
        let result = Selection(startIndex..<endIndex, in: string)
        Log.selector.debug("\(taggerUnit.rawValue) \(direction) from \(selection) → \(result)")
        return result
    }

    /// NaturalLanguage ends sentences inside citations ("1850.[" + "2] It…"): moves such a boundary past them and the space after.
    static func skippingCitations(from boundary: String.Index, in string: String) -> String.Index {
        guard boundary > string.startIndex, string[string.index(before: boundary)] == "[",
            var index = citationEnd(from: boundary, in: string)
        else { return boundary }
        while index < string.endIndex, string[index] == "[", let end = citationEnd(from: string.index(after: index), in: string) {
            index = end
        }
        while index < string.endIndex, string[index].isWhitespace {
            index = string.index(after: index)
        }
        return index
    }

    /// After the "]" closing a short citation whose text starts at `start`.
    private static func citationEnd(from start: String.Index, in string: String) -> String.Index? {
        var index = start
        for _ in 0..<32 {
            guard index < string.endIndex else { return nil }
            let character = string[index]
            if character == "]" { return index > start ? string.index(after: index) : nil }
            if character == "[" || character.isNewline { return nil }
            index = string.index(after: index)
        }
        return nil
    }
}

extension NLTagger {
    func enumerateTagsReversed(
        in range: Range<String.Index>, unit: NLTokenUnit, scheme: NLTagScheme, options: NLTagger.Options = [],
        using block: (NLTag?, Range<String.Index>) -> Bool
    ) {
        guard let string else { return }
        var currentIndex = range.upperBound
        while currentIndex > range.lowerBound {
            let previousIndex = string.index(before: currentIndex)
            let tags = tags(in: previousIndex..<currentIndex, unit: unit, scheme: scheme, options: options)
            guard let (tag, tagRange) = tags.last, tagRange.lowerBound < currentIndex else {
                // Never seen, but always step back so the loop ends
                currentIndex = previousIndex
                continue
            }
            guard block(tag, tagRange) else { break }
            currentIndex = tagRange.lowerBound
        }
    }
}
