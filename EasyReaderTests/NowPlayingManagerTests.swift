import AVFoundation
import Defaults
import MediaPlayer
import Testing

@testable import EasyReader

extension IntegrationTests {
    @MainActor
    struct NowPlayingManagerTests {
        private let reader = EasyReader()
        private let manager: NowPlayingManager
        private let readable = MockReadable("First sentence. Second sentence.")

        init() {
            Defaults[.speechVolume] = 0
            Defaults[.speechRate] = AVSpeechUtteranceMaximumSpeechRate
            let manager = NowPlayingManager(reader: reader)
            self.manager = manager
            let reader = reader
            Teardown.add {
                reader.stop()
                manager.isEnabled = false  // removes targets from the shared command center
            }
        }

        @Test func commandsRegisteredOnlyWhileEnabledAndNotStopped() {
            manager.update(readable: readable, state: .reading)
            #expect(!manager.areCommandsRegistered, "disabled")

            manager.isEnabled = true
            #expect(manager.areCommandsRegistered, "enabled while reading")
            manager.update(readable: readable, state: .paused)
            #expect(manager.areCommandsRegistered, "paused")
            manager.update(readable: readable, state: .stopped)
            #expect(!manager.areCommandsRegistered, "stopped")
        }

        @Test func enablingWhileStoppedRegistersNothing() {
            manager.isEnabled = true
            #expect(!manager.areCommandsRegistered)
        }

        @Test func publishesInfoWhileReading() {
            manager.isEnabled = true
            manager.update(readable: readable, state: .reading)
            let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
            #expect(info?[MPMediaItemPropertyTitle] as? String == readable.title)
            #expect(
                info?[MPNowPlayingInfoPropertyPlaybackRate] as? Float
                    == SpeechRate.multiplier(forRate: Defaults[.speechRate])
            )
        }

        @Test func disablingWhileReadingUnregistersAndClearsInfo() {
            manager.isEnabled = true
            manager.update(readable: readable, state: .reading)
            manager.isEnabled = false
            #expect(!manager.areCommandsRegistered)
            #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo == nil)
        }

        @Test func stoppingClearsInfo() {
            manager.isEnabled = true
            manager.update(readable: readable, state: .reading)
            manager.update(readable: readable, state: .stopped)
            #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo == nil)
        }

        @Test(arguments: [
            NowPlayingManager.Action.play, .pause, .stop, .togglePlayPause, .nextTrack, .previousTrack,
        ])
        func playbackCommandsFailWithoutReadable(action: NowPlayingManager.Action) {
            #expect(manager.perform(action) == .commandFailed)
        }

        @Test func changePlaybackRateSetsClampedSpeechRate() {
            #expect(manager.perform(.changePlaybackRate(10)) == .success)
            #expect(Defaults[.speechRate] == AVSpeechUtteranceMaximumSpeechRate)
        }

        @Test func togglePlayPauseStartsReading() {
            reader.textSelector = NLTextSelector(unit: .sentence)
            reader.readable = readable
            #expect(manager.perform(.togglePlayPause) == .success)
            #expect(readable.history.last.flatMap(readable.text(of:)) == "First sentence.")
        }
    }
}
