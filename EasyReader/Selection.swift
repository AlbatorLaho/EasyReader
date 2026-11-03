//
//  Selection.swift
//  EasyReader
//
//  Created by Ewalk on 24/12/17.
//

import Foundation
import Defaults

struct Selection: Equatable, Hashable {
    let lowerBound: Bound
    let upperBound: Bound
    var count: Bound { upperBound - lowerBound }
    var isEmpty: Bool { lowerBound >= upperBound }
    
    init() {
        lowerBound = 0
        upperBound = 0
    }
    
    init(_ range: CFRange) {
        lowerBound = range.location
        upperBound = range.location + range.length
    }
    
    init(_ range: NSRange) {
        lowerBound = range.location
        upperBound = range.location + range.length
    }
    
    init<R: RangeExpression>(_ region: R) where R.Bound == Bound {
        self.init(NSRange(region))
    }
    
    init<R: RangeExpression, S: StringProtocol>(_ region: R, in string: S) where R.Bound == String.Index {
        self.init(NSRange(region, in: string))
    }
    
    /// Clamped to the string and rounded down to a character boundary, so it's always safe to use
    /// (the text may have changed since the offsets were read, or they may split a surrogate pair).
    func startIndex<S: StringProtocol>(in string: S) -> String.Index {
        return Self.characterIndex(atUTF16Offset: lowerBound, in: string)
    }

    /// See `startIndex(in:)`.
    func endIndex<S: StringProtocol>(in string: S) -> String.Index {
        return Self.characterIndex(atUTF16Offset: upperBound, in: string)
    }

    /// Between `startIndex(in:)` and `endIndex(in:)`.
    func substring<S: StringProtocol>(of string: S) -> String {
        String(string[startIndex(in: string)..<endIndex(in: string)])
    }

    private static func characterIndex<S: StringProtocol>(atUTF16Offset offset: Int, in string: S) -> String.Index {
        let utf16 = string.utf16
        var index = utf16.index(utf16.startIndex, offsetBy: offset.clamped(to: 0...utf16.count))
        while String.Index(index, within: string) == nil {
            index = utf16.index(before: index)
        }
        return index
    }
}

extension Selection: RangeExpression {
    typealias Bound = Int

    func relative<C: Collection>(to collection: C) -> Range<Bound> {
        return lowerBound..<upperBound
    }
    
    func contains(_ element: Bound) -> Bool {
        return element >= lowerBound && element < upperBound
    }
}

extension Selection {
    enum Unit: String, Defaults.Serializable {
        case sentence
        case paragraph
    }
}

//TODO: makes more sense to be called SelectDirection
extension Selection {
    enum Direction {
        case forward
        case backward
    }
}



extension CFRange {
    init(_ selection: Selection) {
        self.init(location: selection.lowerBound, length: selection.count)
    }
}

extension NSRange {
    init(_ selection: Selection) {
        self.init(location: selection.lowerBound, length: selection.count)
    }
}

extension Range<Int> {
    init?(_ selection: Selection) {
        self.init(NSRange(selection))
//        return selection.lowerBound..<selection.upperBound
    }
}

extension Range<String.Index> {
    init?<S: StringProtocol>(_ selection: Selection, in string: S) {
        self.init(NSRange(selection), in: string)
//        return selection.startIndex(in: string)..<selection.endIndex(in: string)
//        let lower = String.Index(utf16Offset: selection.lowerBound, in: string)
//        let upper = String.Index(utf16Offset: selection.upperBound, in: string)
//        self = lower..<upper
//        let lower = string.index(string.startIndex, offsetBy: selection.lowerBound)
//        let upper = string.index(string.startIndex, offsetBy: selection.upperBound)
//        guard let lower = string.index(string.startIndex, offsetBy: selection.lowerBound, limitedBy: string.endIndex),
//              let upper = string.index(string.startIndex, offsetBy: selection.upperBound, limitedBy: string.endIndex)
//        else { return nil }
//        self = lower..<upper
    }
}
