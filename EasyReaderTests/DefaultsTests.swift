import AVFoundation
import Defaults
import Testing

@testable import EasyReader

struct VoiceBridgeTests {
    private let bridge = AVSpeechSynthesisVoice.bridge

    @Test func roundTripsByIdentifier() throws {
        let voice = try #require(AVSpeechSynthesisVoice.speechVoices().first)
        let stored = try #require(bridge.serialize(voice))
        #expect(stored == voice.identifier)
        #expect(bridge.deserialize(stored)?.identifier == voice.identifier)
    }

    /// A voice removed since (or no voice: the system voice) reads back as nil.
    @Test func unknownVoiceIsNil() {
        #expect(bridge.deserialize("com.example.no-such-voice") == nil)
        #expect(bridge.deserialize(nil) == nil)
        #expect(bridge.serialize(nil) == nil)
    }
}

extension IntegrationTests {
    /// Values stored by older versions (or unknown ones) read as the default.
    @MainActor
    struct LegacyDefaultsTests {
        @Test func unknownStopBoundaryIsDefault() {
            UserDefaults.app.set("selectionEnd", forKey: Defaults.Keys.speechStopBoundary.name)
            #expect(Defaults[.speechStopBoundary] == Defaults.Keys.speechStopBoundary.defaultValue)
            UserDefaults.app.set(1, forKey: Defaults.Keys.speechStopBoundary.name)  // an `AVSpeechBoundary` raw value
            #expect(Defaults[.speechStopBoundary] == Defaults.Keys.speechStopBoundary.defaultValue)
        }

        @Test func unknownPlayWhenFinishedIsDefault() {
            UserDefaults.app.set("always", forKey: Defaults.Keys.playWhenFinished.name)
            #expect(Defaults[.playWhenFinished] == .off)
        }

        @Test func unknownPresenceIsDefault() {
            UserDefaults.app.set("nowhere", forKey: Defaults.Keys.appPresence.name)
            #expect(Defaults[.appPresence] == .menuBar)
        }
    }
}
