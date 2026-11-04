//
//  Defaults.swift
//  EasyReader
//
//  Created by Ewalk on 24/12/22.
//

import Foundation
import AVKit
import Defaults
import KeyboardShortcuts

extension UserDefaults {
    /// Settings store. Tests run inside the Debug app (test host), so they get an in-memory store
    /// instead of the Debug app's saved settings.
    static let app: UserDefaults =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil ? .standard : InMemoryDefaults()
}

/// `UserDefaults` that never persists. Posts KVO on writes so `Defaults.updates`/`@Default` still observe changes.
private final class InMemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]

    override func object(forKey defaultName: String) -> Any? { values[defaultName] }

    override func set(_ value: Any?, forKey defaultName: String) {
        willChangeValue(forKey: defaultName)
        values[defaultName] = value
        didChangeValue(forKey: defaultName)
    }

    override func removeObject(forKey defaultName: String) { set(nil, forKey: defaultName) }

    override func dictionaryRepresentation() -> [String: Any] { values }
}

extension Defaults.Keys {
    static let nowPlayingCenterIntegration = Key<Bool>("NowPlayingCenterIntegration", default: true, suite: .app)
//    static let nowPlayingCenterStaysOpen = Key<Bool>("NowPlayingCenterStaysOpen", default: false)

    static let speechVoice = Key<AVSpeechSynthesisVoice?>("SpeechVoice", suite: .app)
    static let speechVolume = Key<Float>("SpeechVolume", default: 1.0, suite: .app)
    static let speechRate = Key<Float>("SpeechRate", default: AVSpeechUtteranceDefaultSpeechRate, suite: .app)
    static let speechPitch = Key<Float>("SpeechPitch", default: 1.0, suite: .app)
    static let speechStopBoundary = Key<AVSpeechBoundary>("SpeechStopBoundary", default: .immediate, suite: .app)
    static let speechDelayBefore = Key<Double>("SpeechDelayBefore", default: 0, suite: .app)
    static let speechDelayAfter = Key<Double>("SpeechDelayAfter", default: 0, suite: .app)

    static let selectionUnit = Key<Selection.Unit>("SelectionUnit", default: .sentence, suite: .app)
    static let resumeUnit = Key<EasyReader.ResumeUnit>("ResumeUnit", default: .word, suite: .app)
    static let scrollSelectionIntoView = Key<Bool>("ScrollSelectionIntoView", default: true, suite: .app)
    static let scrollPadding = Key<Int>("ScrollPadding", default: 16, suite: .app)
    static let scrollSmooth = Key<Bool>("ScrollSmooth", default: true, suite: .app)
    static let scrollDuration = Key<Double>("ScrollDuration", default: 0.3, suite: .app)
    static let scrollUpdateRate = Key<Double>("ScrollUpdateRate", default: 60, suite: .app)

//    static let useVoiceOverPronunciations = Key<Bool>("useVoiceOverPronunciations", default: false)
    static let pronunciations = Key<[Pronunciation]>("Pronunciations", default: [], suite: .app)
}

extension KeyboardShortcuts.Name {
    static let toggleStartStop = Self("ToggleStartStop")
    static let togglePlayPause = Self("TogglePlayPause")
    static let skipForward = Self("SkipForward")
    static let skipBackward = Self("SkipBackward")
    static let increaseRate = Self("IncreaseRate")
    static let decreaseRate = Self("DecreaseRate")
    static let defaultRate = Self("DefaultRate")
}

extension AVSpeechSynthesisVoice: Defaults.Serializable {
    public static let bridge = AVSpeechSynthesisVoiceBridge()
}

public struct AVSpeechSynthesisVoiceBridge: Defaults.Bridge {
    public typealias Value = AVSpeechSynthesisVoice
    public typealias Serializable = String
    
    public func serialize(_ value: Value?) -> Serializable? {
        return value?.identifier
    }

    public func deserialize(_ object: Serializable?) -> Value? {
        guard let object else { return nil }
        return AVSpeechSynthesisVoice(identifier: object)
    }
}

extension AVSpeechBoundary: Defaults.Serializable {
    public static let bridge = AVSpeechBoundaryBridge()
}

public struct AVSpeechBoundaryBridge: Defaults.Bridge {
    public typealias Value = AVSpeechBoundary
    public typealias Serializable = Int
    
    public func serialize(_ value: Value?) -> Serializable? {
        return value?.rawValue
    }

    public func deserialize(_ object: Serializable?) -> Value? {
        guard let object else { return nil }
        return AVSpeechBoundary(rawValue: object)
    }
}

//extension AVSpeechSynthesizer {
////    private static let systemSpeechDefaults = UserDefaults(suiteName: "com.apple.speech.voice.prefs")!
////    private static let systemVoiceOverDefaults = UserDefaults(suiteName: "com.apple.VoiceOver4/default")!
////
////    static let selectedVoiceName = Key<String?>("SelectedVoiceName", suite: systemSpeechDefaults)
////    static let selectedVoiceCreator = Key<Int?>("SelectedVoiceCreator", suite: systemSpeechDefaults)
////    static let selectedVoiceID = Key<Int?>("SelectedVoiceID", suite: systemSpeechDefaults)
////    static let voiceRateDataArray = Key<[[Int]]?>("VoiceRateDataArray", suite: systemSpeechDefaults)
////    static let voiceOverVoiceID = Key<String?>("SCRCategories_SCRCategorySystemWide_SCRSpeechLanguages_default_SCRSpeechComponentSettings_SCRVoiceIdentifier", suite: systemVoiceOverDefaults)
//
//    static func defaultVoice() -> AVSpeechSynthesisVoice? {
////        print(Defaults[.selectedVoiceName])
////        print(Defaults[.selectedVoiceCreator])
////        print(Defaults[.selectedVoiceID])
////        print(Defaults[.voiceRateDataArray])
////        print(Defaults[.voiceOverVoiceID])
//
////        print(AVSpeechSynthesisIPANotationAttribute)
//
//        if let voice = AVSpeechSynthesisVoice(identifier: NSSpeechSynthesizer.defaultVoice.rawValue) { return voice }
//
//        if let voicePreferences = UserDefaults.standard.persistentDomain(forName: "com.apple.speech.voice.prefs"),
//           let voiceName = voicePreferences["SelectedVoiceName"] as? String,
//           let voice = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.name == voiceName })
//        { return voice }
//
//        if let voiceOverPreferences = UserDefaults.standard.persistentDomain(forName: "com.apple.VoiceOver4/default"),
//           let voiceIdentifier = voiceOverPreferences["SCRCategories_SCRCategorySystemWide_SCRSpeechLanguages_default_SCRSpeechComponentSettings_SCRVoiceIdentifier"] as? String,
//           let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier)
//        { return voice }
//
//        if let voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode()) { return voice }
//
//        return nil
//    }
//}
