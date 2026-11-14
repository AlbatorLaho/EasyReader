import ApplicationServices
import Testing

@testable import EasyReader

struct AXValueTests {
    @Test func structsRoundTripThroughAXValue() throws {
        let rect = CGRect(x: 1, y: 2, width: 3, height: 4)
        #expect(CGRect(axValue: rect.axValue) == rect)
        let range = CFRange(location: 5, length: 6)
        let decoded = try #require(CFRange(axValue: range.axValue))
        #expect(decoded.location == 5 && decoded.length == 6)
        #expect(CGPoint(axValue: CGPoint(x: 7, y: 8).axValue) == CGPoint(x: 7, y: 8))
        #expect(CGSize(axValue: CGSize(width: 9, height: 10).axValue) == CGSize(width: 9, height: 10))
    }

    /// A value of another type decodes to `nil` (the element reports it as a type mismatch) instead of crashing.
    @Test func wrongTypeDoesNotDecode() {
        #expect(CGRect(axValue: CFRange(location: 0, length: 1).axValue) == nil)
        #expect(CGRect(axValue: "text" as CFString) == nil)
        #expect(String(axValue: 3 as NSNumber) == nil)
        #expect(AXElement(axValue: "text" as CFString) == nil)
        #expect(AXTextMarker(axValue: "text" as CFString) == nil)
        #expect(AXTextMarkerRange(axValue: CGRect.zero.axValue) == nil)
    }

    @Test func scalarsDecode() {
        #expect(String(axValue: "text" as CFString) == "text")
        #expect(Bool(axValue: kCFBooleanTrue) == true)
        #expect(Bool(axValue: 0 as NSNumber) == false)
        #expect(Int(axValue: 42 as NSNumber) == 42)
        #expect(CGFloat(axValue: 0.25 as NSNumber) == 0.25)
        #expect(AXRole(axValue: "AXWebArea" as CFString) == .webArea)
    }

    @Test func arraysDecodeOnlyIfEveryElementDoes() {
        #expect([String](axValue: ["a", "b"] as CFArray) == ["a", "b"])
        #expect([String](axValue: ["a", 1] as CFArray) == nil)
    }

    /// Chromium 157 wraps search results in dictionaries, 153 doesn't; anything else is skipped, not fatal.
    @Test func searchResultsUnwrapDictionaries() throws {
        let app = AXElement.application(pid: getpid())
        let wrapped = ["AXSearchResultElement": app.raw] as CFDictionary
        let results = try #require([AXSearchResult](axValue: [app.raw, wrapped, "other"] as CFArray))
        #expect(results.map(\.element) == [app, app, nil])
    }

    @Test func elementsCompareByIdentity() {
        let own = AXElement.application(pid: getpid())
        #expect(own == AXElement.application(pid: getpid()))
        #expect(own.hashValue == AXElement.application(pid: getpid()).hashValue)
        #expect(own != AXElement.application(pid: 1))
    }
}
