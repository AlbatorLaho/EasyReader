import Foundation
import Testing

@testable import EasyReader

struct PronunciationTests {
    @Test func codableRoundTrip() throws {
        let pronunciation = Pronunciation(search: "GUI", replace: "gooey", domain: "com.apple.TextEdit", ignoreCase: false, enabled: false)
        let data = try JSONEncoder().encode(pronunciation)
        #expect(try JSONDecoder().decode(Pronunciation.self, from: data) == pronunciation)
    }

    @Test func uniqueIDs() {
        let a = Pronunciation(search: "x", replace: "y", ignoreCase: true, enabled: true)
        let b = Pronunciation(search: "x", replace: "y", ignoreCase: true, enabled: true)
        #expect(a.id != b.id)
    }
}
