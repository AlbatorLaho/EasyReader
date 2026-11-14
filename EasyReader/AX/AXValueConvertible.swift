import ApplicationServices
import Foundation

protocol AXDecodable {
    init?(axValue: AnyObject)
}

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

/// Wrapper because a class can't conform to `AXDecodable` itself.
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

struct AXTextMarker: AXValueConvertible, Equatable {
    let raw: AnyObject

    init?(axValue: AnyObject) {
        guard TextMarkerSPI.isMarker(axValue) else { return nil }
        raw = axValue
    }

    var axValue: AnyObject { raw }

    static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.raw, rhs.raw) }
}

struct AXTextMarkerRange: AXValueConvertible, Equatable {
    let raw: AnyObject

    init?(axValue: AnyObject) {
        guard TextMarkerSPI.isMarkerRange(axValue) else { return nil }
        raw = axValue
    }

    /// Made locally (no IPC), for apps without `AXTextMarkerRangeForUnorderedTextMarkers` (Catalyst).
    init?(start: AXTextMarker, end: AXTextMarker) {
        guard let raw = TextMarkerSPI.range(from: start.raw, to: end.raw) else { return nil }
        self.raw = raw
    }

    var axValue: AnyObject { raw }

    // Only Firefox has `AXStartTextMarkerForTextMarkerRange`, so these go through HIServices directly.
    var start: AXTextMarker? { TextMarkerSPI.start(of: raw).flatMap(AXTextMarker.init(axValue:)) }
    var end: AXTextMarker? { TextMarkerSPI.end(of: raw).flatMap(AXTextMarker.init(axValue:)) }

    static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.raw, rhs.raw) }
}

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

/// Chromium 157 wraps each result as `{AXSearchResultElement: element}`, older ones return bare elements (an `[AXUIElement]` cast lets dicts through).
struct AXSearchResult: AXDecodable {
    /// `nil` for a result of another kind (skipped, not failing the whole list).
    let element: AXElement?

    init?(axValue: AnyObject) {
        element = AXElement(axValue: (axValue as? [String: AnyObject])?["AXSearchResultElement"] ?? axValue)
    }
}

struct AXTextOperation: AXEncodable {
    let type: String
    let ranges: [AXTextMarkerRange]

    static func select(_ range: AXTextMarkerRange) -> Self { Self(type: "TextOperationSelect", ranges: [range]) }

    var axValue: AnyObject {
        let operation: [String: Any] = ["AXTextOperationType": type, "AXTextOperationMarkerRanges": ranges.map(\.raw)]
        return operation as CFDictionary
    }
}

/// For results nobody reads.
struct AXAnyValue: AXDecodable {
    let raw: AnyObject

    init?(axValue: AnyObject) {
        raw = axValue
    }
}

/// HIServices text-marker functions: not in the SDK headers, but exported.
private enum TextMarkerSPI {
    private typealias CopyMarker = @convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>?
    private typealias GetTypeID = @convention(c) () -> CFTypeID
    private typealias CreateRange = @convention(c) (CFAllocator?, CFTypeRef, CFTypeRef) -> Unmanaged<CFTypeRef>?

    private static let copyStart: CopyMarker? = load("AXTextMarkerRangeCopyStartMarker")
    private static let copyEnd: CopyMarker? = load("AXTextMarkerRangeCopyEndMarker")
    private static let createRange: CreateRange? = load("AXTextMarkerRangeCreate")
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
    static func range(from start: AnyObject, to end: AnyObject) -> AnyObject? { createRange?(nil, start, end)?.takeRetainedValue() }
}
