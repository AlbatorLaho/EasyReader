import AVFoundation
import Testing

@testable import EasyReader

func isClose(_ a: Float, _ b: Float, tolerance: Float = 0.001) -> Bool {
    abs(a - b) <= tolerance
}

struct SpeechRateTests {
    @Test(
        arguments: [
            (AVSpeechUtteranceMinimumSpeechRate, 0.5),
            (AVSpeechUtteranceDefaultSpeechRate, 1),
            (AVSpeechUtteranceMaximumSpeechRate, 4),
        ] as [(Float, Float)])
    func knownPoints(rate: Float, multiplier: Float) {
        #expect(isClose(SpeechRate.multiplier(forRate: rate), multiplier))
    }

    @Test(arguments: 0...20)
    func roundTripsAcrossRange(step: Int) {
        let rate = Float(step) / 20
        #expect(isClose(SpeechRate.rate(forMultiplier: SpeechRate.multiplier(forRate: rate)), rate))
    }

    @Test(arguments: [Float(0.25), 0.5, 0.75])
    func steppedMovesOneStepInSpeed(rate: Float) {
        let before = SpeechRate.multiplier(forRate: rate)
        #expect(isClose(SpeechRate.multiplier(forRate: SpeechRate.stepped(rate, by: 1)), before + SpeechRate.step))
        #expect(isClose(SpeechRate.multiplier(forRate: SpeechRate.stepped(rate, by: -1)), before - SpeechRate.step))
    }

    /// 1.1× is between steps: up goes to 1.25×, down to 1×.
    @Test func steppedSnapsToStep() {
        let rate = SpeechRate.rate(forMultiplier: 1.1)
        #expect(isClose(SpeechRate.multiplier(forRate: SpeechRate.stepped(rate, by: 1)), 1.25))
        #expect(isClose(SpeechRate.multiplier(forRate: SpeechRate.stepped(rate, by: -1)), 1))
    }

    @Test func steppedClampsAtEnds() {
        #expect(SpeechRate.stepped(AVSpeechUtteranceMaximumSpeechRate, by: 1) == AVSpeechUtteranceMaximumSpeechRate)
        #expect(SpeechRate.stepped(AVSpeechUtteranceMinimumSpeechRate, by: -1) == AVSpeechUtteranceMinimumSpeechRate)
    }

    @Test func multiplierIncreasesWithRate() {
        var previous = -Float.infinity
        for step in 0...100 {
            let multiplier = SpeechRate.multiplier(forRate: Float(step) / 100)
            #expect(multiplier > previous, "step \(step)")
            previous = multiplier
        }
    }

    @Test(arguments: [(-0.5, 0), (0, 0), (0.3, 0.3), (1, 1), (1.5, 1)] as [(Float, Float)])
    func clamped(rate: Float, expected: Float) {
        #expect(SpeechRate.clamped(rate) == expected)
    }

    /// Multipliers outside 0.5–4× map to rates outside 0–1 (not clamped), which `clamped` brings back.
    @Test func outOfRangeMultipliers() {
        #expect(isClose(SpeechRate.rate(forMultiplier: 0.25), -0.25))
        #expect(SpeechRate.rate(forMultiplier: 5) > AVSpeechUtteranceMaximumSpeechRate)
        #expect(SpeechRate.clamped(SpeechRate.rate(forMultiplier: 0.25)) == AVSpeechUtteranceMinimumSpeechRate)
        #expect(SpeechRate.clamped(SpeechRate.rate(forMultiplier: 5)) == AVSpeechUtteranceMaximumSpeechRate)
    }
}
