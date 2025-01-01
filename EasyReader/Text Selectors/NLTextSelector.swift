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
                let tags = tagger.tags(in: string.startIndex..<endIndex, unit: taggerUnit, scheme: .lexicalClass)
//                print(tags.map({ _, range in NSRange(range, in: string) }))
                let tag = tags.last(where: { tag, _ in tag != .paragraphBreak }).map({ _, range in range })
                startIndex = tag?.lowerBound ?? string.startIndex
            case .forward:
                startIndex = selection.endIndex(in: string)
                let tags = tagger.tags(in: startIndex..<string.endIndex, unit: taggerUnit, scheme: .lexicalClass)
//                print(tags.map({ _, range in NSRange(range, in: string) }))
                let tag = tags.first(where: { tag, _ in tag != .paragraphBreak }).map({ _, range in range })
                endIndex = tag?.upperBound ?? string.endIndex
        }
        print(Selection(startIndex..<endIndex, in: string))
//        print(String(string[startIndex..<endIndex]))
        return Selection(startIndex..<endIndex, in: string)
    }
}
