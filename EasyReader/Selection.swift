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
    
    func startIndex<S: StringProtocol>(in string: S) -> String.Index {
        return String.Index(utf16Offset: lowerBound, in: string)
    }
    
    func endIndex<S: StringProtocol>(in string: S) -> String.Index {
        return String.Index(utf16Offset: upperBound, in: string)
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
        case backward
        case forward
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
