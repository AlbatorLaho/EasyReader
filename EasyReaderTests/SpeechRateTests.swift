//
//  SpeechRateTests.swift
//  EasyReaderTests
//

import AVFoundation
import XCTest

@testable import EasyReader

final class SpeechRateTests: XCTestCase {
    func testKnownPoints() {
        XCTAssertEqual(SpeechRate.multiplier(forRate: AVSpeechUtteranceMinimumSpeechRate), 0.5, accuracy: 0.001)
        XCTAssertEqual(SpeechRate.multiplier(forRate: AVSpeechUtteranceDefaultSpeechRate), 1, accuracy: 0.001)
        XCTAssertEqual(SpeechRate.multiplier(forRate: AVSpeechUtteranceMaximumSpeechRate), 4, accuracy: 0.001)
    }

    func testRoundTripsAcrossRange() {
        for step in 0...20 {
            let rate = Float(step) / 20
            XCTAssertEqual(SpeechRate.rate(forMultiplier: SpeechRate.multiplier(forRate: rate)), rate, accuracy: 0.001)
        }
    }

    func testAdjustedStepsEvenlyInSpeed() {
        for rate: Float in [0.2, 0.5, 0.8] {
            let before = SpeechRate.multiplier(forRate: rate)
            XCTAssertEqual(SpeechRate.multiplier(forRate: SpeechRate.adjusted(rate, byMultiplier: 0.1)), before + 0.1, accuracy: 0.001)
            XCTAssertEqual(SpeechRate.multiplier(forRate: SpeechRate.adjusted(rate, byMultiplier: -0.1)), before - 0.1, accuracy: 0.001)
        }
    }

    func testAdjustedClampsAtEnds() {
        XCTAssertEqual(SpeechRate.adjusted(AVSpeechUtteranceMaximumSpeechRate, byMultiplier: 0.1), AVSpeechUtteranceMaximumSpeechRate)
        XCTAssertEqual(SpeechRate.adjusted(AVSpeechUtteranceMinimumSpeechRate, byMultiplier: -0.1), AVSpeechUtteranceMinimumSpeechRate)
    }

    func testIsIncreasing() {
        var previous = -Float.infinity
        for step in 0...100 {
            let multiplier = SpeechRate.multiplier(forRate: Float(step) / 100)
            XCTAssertGreaterThan(multiplier, previous)
            previous = multiplier
        }
    }
}
