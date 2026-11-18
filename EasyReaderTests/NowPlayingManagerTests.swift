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

        /// Pausing holds the elapsed time instead of resetting it.
        @Test func publishesProgressAsTime() throws {
            manager.isEnabled = true
            let progress = EasyReader.Progress(position: 34, length: 340)
            let cps = NowPlayingManager.charactersPerSecond
            manager.update(readable: readable, state: .reading, progress: progress)
            var info = try #require(MPNowPlayingInfoCenter.default().nowPlayingInfo)
            #expect(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 34 / cps)
            #expect(info[MPMediaItemPropertyPlaybackDuration] as? Double == 340 / cps)

            manager.update(readable: readable, state: .paused, progress: progress)
            info = try #require(MPNowPlayingInfoCenter.default().nowPlayingInfo)
            #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Float == 0)
            #expect(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 34 / cps)
        }

        @Test(arguments: [NowPlayingManager.PlayWhenFinished.sameText, .sameApp, .anyText])
        func keepsCommandsAfterFinishing(setting: NowPlayingManager.PlayWhenFinished) throws {
            Defaults[.playWhenFinished] = setting
            manager.isEnabled = true
            let progress = EasyReader.Progress(position: 300, length: 340)
            manager.update(readable: readable, state: .stopped, progress: progress, hasFinished: true)
            #expect(manager.areCommandsRegistered)
            let info = try #require(MPNowPlayingInfoCenter.default().nowPlayingInfo)
            #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Float == 0)
            #expect(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 340 / NowPlayingManager.charactersPerSecond)
        }

        @Test func releasesCommandsAfterFinishingWhenOff() {
            Defaults[.playWhenFinished] = .off
            manager.isEnabled = true
            manager.update(readable: readable, state: .reading)
            manager.update(readable: readable, state: .stopped, hasFinished: true)
            #expect(!manager.areCommandsRegistered)
            #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo == nil)
        }

        @Test func noTimeWithoutProgress() throws {
            manager.isEnabled = true
            manager.update(readable: readable, state: .reading)
            let info = try #require(MPNowPlayingInfoCenter.default().nowPlayingInfo)
            #expect(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] == nil)
            #expect(info[MPMediaItemPropertyPlaybackDuration] == nil)
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
            .seek(.forward, begin: true), .seek(.backward, begin: true),
        ])
        func playbackCommandsFailWithoutReadable(action: NowPlayingManager.Action) {
            #expect(manager.perform(action) == .commandFailed)
        }

        @Test func changePlaybackRateSetsClampedSpeechRate() {
            #expect(manager.perform(.changePlaybackRate(10)) == .success)
            #expect(Defaults[.speechRate] == AVSpeechUtteranceMaximumSpeechRate)
        }

        /// Holding ⏭ skips on begin and every interval until the end event; slowest rate so units don't finish meanwhile.
        @Test func holdingNextSkipsRepeatedlyUntilReleased() async {
            Defaults[.speechRate] = AVSpeechUtteranceMinimumSpeechRate
            let readable = MockReadable(longText)
            reader.textSelector = NLTextSelector(unit: .sentence)
            reader.readable = readable
            Defaults[.repeatingSkipInterval] = 0.2
            let interval = EasyReader.repeatingSkipInterval
            let before = readable.history.count

            #expect(manager.perform(.seek(.forward, begin: true)) == .success)
            await settle(interval * 2.5)
            #expect(manager.perform(.seek(.forward, begin: false)) == .success)
            let skips = readable.history.count - before
            #expect(skips == 3)

            await settle(interval * 2)
            #expect(readable.history.count - before == skips, "no skips after release")
        }

        @Test func stoppingEndsRepeatingSkip() async {
            Defaults[.speechRate] = AVSpeechUtteranceMinimumSpeechRate
            let readable = MockReadable(longText)
            reader.textSelector = NLTextSelector(unit: .sentence)
            reader.readable = readable

            #expect(manager.perform(.seek(.forward, begin: true)) == .success)
            reader.stop()
            manager.update(readable: readable, state: .stopped)
            let count = readable.history.count
            await settle(EasyReader.repeatingSkipInterval * 2)
            #expect(readable.history.count == count)
        }

        @Test func togglePlayPauseStartsReading() {
            reader.textSelector = NLTextSelector(unit: .sentence)
            reader.readable = readable
            #expect(manager.perform(.togglePlayPause) == .success)
            #expect(readable.history.last.flatMap(readable.text(of:)) == "First sentence.")
        }

        @Test func playWhileReadingKeepsReading() async throws {
            let recorder = StateRecorder()
            reader.delegate = recorder
            reader.textSelector = NLTextSelector(unit: .sentence)
            let reading = recorder.expect(.reading)
            #expect(reader.start(reading: MockReadable(longText)))
            try await reading.wait(timeout: 10)
            let starts = recorder.progressAtStarts.count
            #expect(manager.perform(.play) == .success)
            await settle(0.3)
            #expect(recorder.progressAtStarts.count == starts, "no restart")
            #expect(reader.state == .reading)
        }

        @Test func playWhilePausedFollowsResumeUnit() async throws {
            let recorder = StateRecorder()
            reader.delegate = recorder
            reader.textSelector = NLTextSelector(unit: .sentence)
            let long = Array(repeating: "word", count: 200).joined(separator: " ")
            let reading = recorder.expect(.reading)
            #expect(reader.start(reading: MockReadable("\(long). Second sentence.")))
            try await reading.wait(timeout: 10)
            await settle(2)  // a long utterance's first `willSpeakRange` lags ~0.5–1.2 s
            let paused = recorder.expect(.paused)
            #expect(reader.pause())
            try await paused.wait(timeout: 10)
            let resumed = recorder.expect(.reading)
            #expect(manager.perform(.play) == .success)
            try await resumed.wait(timeout: 10)
            let spoken = try #require(reader.spokenText)
            #expect(spoken.original.count < long.count, "resumed mid-sentence")
        }
    }
}
