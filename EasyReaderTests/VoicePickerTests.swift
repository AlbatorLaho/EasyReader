import AVFoundation
import Foundation
import Testing

@testable import EasyReader

struct VoicePickerTests {
    /// Languages are listed by the name shown, not by code (de-DE "German" after en-US "English").
    @Test func languagesSortedByShownName() throws {
        let voices = ["es-ES", "de-DE", "en-US"].compactMap(AVSpeechSynthesisVoice.init(language:))
        try #require(voices.count == 3)
        let languages = VoicePicker.languages(of: voices, locale: Locale(identifier: "en_US")).map(\.language)
        #expect(languages == ["English (United States)", "German (Germany)", "Spanish (Spain)"])
    }
}
