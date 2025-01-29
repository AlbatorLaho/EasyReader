//
//  NLTextSelector.swift
//  EasyReader
//
//  Created by Ewalk on 24/12/19.
//

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
            case .backward:
                endIndex = selection.startIndex(in: string)
                var tagRange: Range<String.Index>?
                tagger.enumerateTagsReversed(in: string.startIndex..<endIndex, unit: taggerUnit, scheme: .lexicalClass) { tag, range in
                    guard tag != .paragraphBreak else { return true }
                    tagRange = range
                    return false
                }
                startIndex = tagRange?.lowerBound ?? string.startIndex
            case .forward:
                startIndex = selection.endIndex(in: string)
                var tagRange: Range<String.Index>?
                tagger.enumerateTags(in: startIndex..<string.endIndex, unit: taggerUnit, scheme: .lexicalClass) { tag, range in
                    guard tag != .paragraphBreak else { return true }
                    tagRange = range
                    return false
                }
                endIndex = tagRange?.upperBound ?? string.endIndex
        }
        print(Selection(startIndex..<endIndex, in: string))
//        print(String(string[startIndex..<endIndex]))
        return Selection(startIndex..<endIndex, in: string)
    }
}

extension NLTagger {
    func enumerateTagsReversed(in range: Range<String.Index>, unit: NLTokenUnit, scheme: NLTagScheme, options: NLTagger.Options = [], using block: (NLTag?, Range<String.Index>) -> Bool) {
        guard let string else { return }
        var currentIndex = range.upperBound
        while currentIndex > range.lowerBound {
            let tags = tags(in: string.index(before: currentIndex)..<currentIndex, unit: unit, scheme: scheme, options: options)
            guard let (tag, tagRange) = tags.last else { continue }
            guard block(tag, tagRange) else { break }
            currentIndex = tagRange.lowerBound
        }
    }
}
