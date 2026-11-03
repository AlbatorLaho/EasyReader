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
            case .forward:
                startIndex = selection.endIndex(in: string)
                var tagRange: Range<String.Index>?
                tagger.enumerateTags(in: startIndex..<string.endIndex, unit: taggerUnit, scheme: .lexicalClass) { tag, range in
                    guard tag != .paragraphBreak else { return true }
                    tagRange = range
                    return false
                }
                endIndex = tagRange?.upperBound ?? string.endIndex
            case .backward:
                endIndex = selection.startIndex(in: string)
                var tagRange: Range<String.Index>?
                tagger.enumerateTagsReversed(in: string.startIndex..<endIndex, unit: taggerUnit, scheme: .lexicalClass) { tag, range in
                    guard tag != .paragraphBreak else { return true }
                    tagRange = range
                    return false
                }
                startIndex = tagRange?.lowerBound ?? string.startIndex
        }
        let result = Selection(startIndex..<endIndex, in: string)
        Log.selector.debug("\(taggerUnit.rawValue) \(direction) from \(selection) → \(result)")
        return result
    }
}

extension NLTagger {
    func enumerateTagsReversed(in range: Range<String.Index>, unit: NLTokenUnit, scheme: NLTagScheme, options: NLTagger.Options = [], using block: (NLTag?, Range<String.Index>) -> Bool) {
        guard let string else { return }
        var currentIndex = range.upperBound
        while currentIndex > range.lowerBound {
            let previousIndex = string.index(before: currentIndex)
            let tags = tags(in: previousIndex..<currentIndex, unit: unit, scheme: scheme, options: options)
            guard let (tag, tagRange) = tags.last, tagRange.lowerBound < currentIndex else {
                // Never seen in practice; step back anyway so the loop always terminates.
                currentIndex = previousIndex
                continue
            }
            guard block(tag, tagRange) else { break }
            currentIndex = tagRange.lowerBound
        }
    }
}
