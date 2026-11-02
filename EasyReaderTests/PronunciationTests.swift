import XCTest
@testable import EasyReader

final class PronunciationTests: XCTestCase {
    func testCompareOptions() {
        XCTAssertEqual(Pronunciation(search: "a", replace: "b", ignoreCase: true, enabled: true).options, [.caseInsensitive])
        XCTAssertEqual(Pronunciation(search: "a", replace: "b", ignoreCase: false, enabled: true).options, [])
    }

    func testCodableRoundTrip() throws {
        let pronunciation = Pronunciation(search: "GUI", replace: "gooey", domain: "com.apple.TextEdit", ignoreCase: false, enabled: false)
        let data = try JSONEncoder().encode(pronunciation)
        XCTAssertEqual(try JSONDecoder().decode(Pronunciation.self, from: data), pronunciation)
    }

    func testUniqueIDs() {
        let a = Pronunciation(search: "x", replace: "y", ignoreCase: true, enabled: true)
        let b = Pronunciation(search: "x", replace: "y", ignoreCase: true, enabled: true)
        XCTAssertNotEqual(a.id, b.id)
    }
}
