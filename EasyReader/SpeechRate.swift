import AVFoundation

/// `AVSpeechUtterance.rate` (what `Defaults[.speechRate]` stores) ↔ speed multiplier (1 = default speed).
/// The rate isn't linear in speed. Measured with the default voice (other voices differ slightly):
///
///     rate   0.0  0.1  0.2  0.3  0.4  0.5  0.6  0.7  0.8  0.9  1.0
///     speed  .56  .67  .72  .83  .91  1    1.59 2.11 2.80 3.52 4.02
///
/// Two lines fit every point within ~0.1×: `0.5 + rate` up to the default, `1 + 6 × (rate − 0.5)` above.
enum SpeechRate {
    static let minimumMultiplier = multiplier(forRate: AVSpeechUtteranceMinimumSpeechRate)  // 0.5×
    static let maximumMultiplier = multiplier(forRate: AVSpeechUtteranceMaximumSpeechRate)  // 4×

    static func multiplier(forRate rate: Float) -> Float {
        rate <= AVSpeechUtteranceDefaultSpeechRate
            ? 0.5 + rate
            : 1 + 6 * (rate - AVSpeechUtteranceDefaultSpeechRate)
    }

    static func clamped(_ rate: Float) -> Float {
        rate.clamped(to: AVSpeechUtteranceMinimumSpeechRate...AVSpeechUtteranceMaximumSpeechRate)
    }

    /// Speed step of the settings slider and the rate shortcuts.
    static let step: Float = 0.25

    /// Moves the speed by `steps` steps; a speed between steps first moves to the next one in that direction.
    static func stepped(_ rate: Float, by steps: Int) -> Float {
        let position = multiplier(forRate: rate) / step
        let nearest = position.rounded()
        let base = abs(position - nearest) < 0.01 ? nearest : position.rounded(steps > 0 ? .down : .up)
        return clamped(self.rate(forMultiplier: (base + Float(steps)) * step))
    }

    /// Not clamped.
    static func rate(forMultiplier multiplier: Float) -> Float {
        multiplier <= 1
            ? multiplier - 0.5
            : AVSpeechUtteranceDefaultSpeechRate + (multiplier - 1) / 6
    }
}
