//
//  TextSelector.swift
//  EasyReader
//
//  Created by Ewalk on 24/11/4.
//

import Foundation

protocol TextSelector {
    init(unit: Selection.Unit);

    func select(_ direction: Selection.Direction, from selection: Selection, in string: String) -> Selection;
}

extension TextSelector {
    /// Like `select(_:from:in:)`, but within the text blocks (paragraphs, headings, list items…) that `block` reports:
    /// a unit never spans two blocks, and blocks with nothing to read (only whitespace or U+FFFC object replacement
    /// characters, e.g. images) are skipped. For text whose blocks aren't separated by line breaks (Chromium page text:
    /// "HeadingFirst sentence."), where sentence detection alone would run them together.
    ///
    /// `block(offset)` returns the block holding the character at UTF-16 `offset`, or nil if unknown (then this falls
    /// back to the whole string). Only blocks near `selection` are requested, and the selector only sees one block, so
    /// this is also much faster on long text.
    func select(
        _ direction: Selection.Direction, from selection: Selection, in string: String, blocks block: (Int) -> Selection?
    ) -> Selection {
        let count = string.utf16.count
        var position = direction == .forward ? selection.upperBound : selection.lowerBound
        for _ in 0..<200 {
            guard direction == .forward ? position < count : position > 0 else { return Selection(position..<position) }
            guard let range = block(direction == .forward ? position : position - 1),
                range.lowerBound <= position, position <= range.upperBound, !range.isEmpty
            else { break }
            let local = String(string[range.startIndex(in: string)..<range.endIndex(in: string)])
            let localPosition = position - range.lowerBound
            let found = select(direction, from: Selection(localPosition..<localPosition), in: local)
            if !Self.isBlank(found, in: local) {
                return Selection(range.lowerBound + found.lowerBound..<range.lowerBound + found.upperBound)
            }
            position = direction == .forward ? range.upperBound : range.lowerBound
        }
        return select(direction, from: Selection(position..<position), in: string)
    }

    private static func isBlank(_ selection: Selection, in string: String) -> Bool {
        string[selection.startIndex(in: string)..<selection.endIndex(in: string)].unicodeScalars.allSatisfy {
            $0 == "\u{FFFC}" || CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }
}
