//
//  AXValueConvertible.swift
//  EasyReader
//

import ApplicationServices
import Foundation

/// A type an attribute value can be read as: `nil` when the value has another type.
protocol AXDecodable {
    init?(axValue: AnyObject)
}

/// A type that can be passed to the AX API (attribute value or parameter).
protocol AXEncodable {
    var axValue: AnyObject { get }
}

typealias AXValueConvertible = AXDecodable & AXEncodable

extension String: AXValueConvertible {
    init?(axValue: AnyObject) {
        guard let string = axValue as? String else { return nil }
        self = string
    }

    var axValue: AnyObject { self as CFString }
}

/// An `NSAttributedString` value (a class can't conform to `AXDecodable` itself).
struct AXAttributedString: AXDecodable {
    let string: NSAttributedString

    init?(axValue: AnyObject) {
        guard let string = axValue as? NSAttributedString else { return nil }
        self.string = string
    }
}

extension Bool: AXValueConvertible {
    init?(axValue: AnyObject) {
        guard let number = axValue as? NSNumber else { return nil }
        self = number.boolValue
    }

    var axValue: AnyObject { self ? kCFBooleanTrue : kCFBooleanFalse }
}

extension Int: AXValueConvertible {
    init?(axValue: AnyObject) {
        guard let number = axValue as? NSNumber else { return nil }
        self = number.intValue
    }

    var axValue: AnyObject { self as NSNumber }
}

extension CGFloat: AXValueConvertible {
    init?(axValue: AnyObject) {
        guard let number = axValue as? NSNumber else { return nil }
        self = CGFloat(number.doubleValue)
    }

    var axValue: AnyObject { self as NSNumber }
}

extension AXRole: AXValueConvertible {
    init?(axValue: AnyObject) {
        guard let string = axValue as? String else { return nil }
        self.init(rawValue: string)
    }

    var axValue: AnyObject { rawValue as CFString }
}

extension AXElement: AXValueConvertible {
    init?(axValue: AnyObject) {
        guard CFGetTypeID(axValue) == AXUIElementGetTypeID() else { return nil }
        self.init(axValue as! AXUIElement)
    }

    var axValue: AnyObject { raw }
}

extension Array: AXDecodable where Element: AXDecodable {
    /// `nil` if any element has another type.
    init?(axValue: AnyObject) {
        guard let values = axValue as? [AnyObject] else { return nil }
        var result: [Element] = []
        result.reserveCapacity(values.count)
        for value in values {
            guard let element = Element(axValue: value) else { return nil }
            result.append(element)
        }
        self = result
    }
}

extension Array: AXEncodable where Element: AXEncodable {
    var axValue: AnyObject { map(\.axValue) as CFArray }
}

// MARK: AXValue structs

/// Structs the AX API wraps in an `AXValue`.
protocol AXValueStruct: AXValueConvertible {
    static var axType: AXValueType { get }
    init()
}

extension AXValueStruct {
    init?(axValue: AnyObject) {
        guard CFGetTypeID(axValue) == AXValueGetTypeID() else { return nil }
        let value = axValue as! AXValue
        var result = Self()
        guard AXValueGetType(value) == Self.axType, withUnsafeMutablePointer(to: &result, { AXValueGetValue(value, Self.axType, $0) })
        else { return nil }
        self = result
    }

    var axValue: AnyObject {
        withUnsafePointer(to: self) { AXValueCreate(Self.axType, $0)! }
    }
}

extension CGPoint: AXValueStruct {
    static var axType: AXValueType { .cgPoint }
}

extension CGSize: AXValueStruct {
    static var axType: AXValueType { .cgSize }
}

extension CGRect: AXValueStruct {
    static var axType: AXValueType { .cgRect }
}

extension CFRange: AXValueStruct {
    static var axType: AXValueType { .cfRange }
}

// MARK: Web

/// A position in a web page's text (WebKit, Chromium, Firefox): an opaque CF type.
struct AXTextMarker: AXValueConvertible, Equatable {
    let raw: AnyObject

    init?(axValue: AnyObject) {
        guard TextMarkerSPI.isMarker(axValue) else { return nil }
        raw = axValue
    }

    var axValue: AnyObject { raw }

    static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.raw, rhs.raw) }
}

/// A range between two text markers: an opaque CF type.
struct AXTextMarkerRange: AXValueConvertible, Equatable {
    let raw: AnyObject

    init?(axValue: AnyObject) {
        guard TextMarkerSPI.isMarkerRange(axValue) else { return nil }
        raw = axValue
    }

    var axValue: AnyObject { raw }

    /// Only Firefox has `AXStartTextMarkerForTextMarkerRange`, so these use HIServices' own functions.
    var start: AXTextMarker? { TextMarkerSPI.start(of: raw).flatMap(AXTextMarker.init(axValue:)) }
    var end: AXTextMarker? { TextMarkerSPI.end(of: raw).flatMap(AXTextMarker.init(axValue:)) }

    static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.raw, rhs.raw) }
}

/// `AXUIElementsForSearchPredicate`'s parameter.
struct AXSearchPredicate: AXEncodable {
    let searchKey: String

    static let staticText = AXSearchPredicate(searchKey: "AXStaticTextSearchKey")

    var axValue: AnyObject {
        let predicate: [String: Any] = [
            "AXSearchKey": searchKey, "AXDirection": "AXDirectionNext", "AXResultsLimit": 1_000_000,
        ]
        return predicate as CFDictionary
    }
}

/// One `AXUIElementsForSearchPredicate` result. Newer Chromium (157) wraps each element in a dictionary; older versions
/// return the elements themselves. (`[AXUIElement]` casts would accept the dictionaries too: CF types aren't checked
/// when bridging.)
struct AXSearchResult: AXDecodable {
    /// `nil` for a result of another kind (skipped, not failing the whole list).
    let element: AXElement?

    init?(axValue: AnyObject) {
        element = AXElement(axValue: (axValue as? [String: AnyObject])?["AXSearchResultElement"] ?? axValue)
    }
}

/// `AXTextOperation`'s parameter (Chromium).
struct AXTextOperation: AXEncodable {
    let type: String
    let ranges: [AXTextMarkerRange]

    static func select(_ range: AXTextMarkerRange) -> Self { Self(type: "TextOperationSelect", ranges: [range]) }

    var axValue: AnyObject {
        let operation: [String: Any] = ["AXTextOperationType": type, "AXTextOperationMarkerRanges": ranges.map(\.raw)]
        return operation as CFDictionary
    }
}

/// A value of any type, for results nobody reads.
struct AXAnyValue: AXDecodable {
    let raw: AnyObject

    init?(axValue: AnyObject) {
        raw = axValue
    }
}

/// HIServices functions for text markers. Not in the SDK headers, but exported (WebKit and assistive apps use them).
private enum TextMarkerSPI {
    private typealias CopyMarker = @convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>?
    private typealias GetTypeID = @convention(c) () -> CFTypeID

    private static let copyStart: CopyMarker? = load("AXTextMarkerRangeCopyStartMarker")
    private static let copyEnd: CopyMarker? = load("AXTextMarkerRangeCopyEndMarker")
    private static let markerTypeID = (load("AXTextMarkerGetTypeID") as GetTypeID?)?()
    private static let markerRangeTypeID = (load("AXTextMarkerRangeGetTypeID") as GetTypeID?)?()

    private static func load<T>(_ name: String) -> T? {
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
        guard let symbol = dlsym(defaultHandle, name) else {
            Log.accessibility.error("\(name) unavailable")
            return nil
        }
        return unsafeBitCast(symbol, to: T.self)
    }

    /// Without the type IDs, any value passes.
    static func isMarker(_ value: AnyObject) -> Bool { markerTypeID.map { CFGetTypeID(value) == $0 } ?? true }
    static func isMarkerRange(_ value: AnyObject) -> Bool { markerRangeTypeID.map { CFGetTypeID(value) == $0 } ?? true }

    static func start(of range: AnyObject) -> AnyObject? { copyStart?(range)?.takeRetainedValue() }
    static func end(of range: AnyObject) -> AnyObject? { copyEnd?(range)?.takeRetainedValue() }
}
