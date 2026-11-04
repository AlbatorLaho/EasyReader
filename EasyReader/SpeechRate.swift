//
//  SpeechRate.swift
//  EasyReader
//

import AVFoundation

/// Maps `AVSpeechUtterance.rate` (0...1, default 0.5, what `Defaults[.speechRate]` stores) to a
/// speaking-speed multiplier (1 = default speed) and back.
///
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

    /// Writers clamp rather than a separate clamping loop, which raced the speech-settings restart.
    static func clamped(_ rate: Float) -> Float {
        rate.clamped(to: AVSpeechUtteranceMinimumSpeechRate...AVSpeechUtteranceMaximumSpeechRate)
    }

    /// `rate` sped up or slowed down by `delta` of real speed (e.g. 0.1 = +0.1×), so steps feel even
    /// across the whole range; clamped.
    static func adjusted(_ rate: Float, byMultiplier delta: Float) -> Float {
        clamped(self.rate(forMultiplier: multiplier(forRate: rate) + delta))
    }

    /// Inverse of `multiplier(forRate:)`; not clamped (use `clamped(_:)` before writing).
    static func rate(forMultiplier multiplier: Float) -> Float {
        multiplier <= 1
            ? multiplier - 0.5
            : AVSpeechUtteranceDefaultSpeechRate + (multiplier - 1) / 6
    }
}
