//
//  Defaults.swift
//  EasyReader
//
//  Created by Ewalk on 24/12/22.
//

import Foundation
import AVKit
import Defaults

extension Defaults.Keys {
//    static let nowPlayingStaysOpen = Key<Bool>("nowPlayingStaysOpen", default: false)
//    resume from start of word, selection, ¿file?, what else?
//    static let mowPlayingPauseType = Key<Bool>("mowPlayingPauseType", default: true)
//    static let useNowPlaying = Key<Bool>("useNowPlaying", default: true)

//    static let useSystemVoice = Key<Bool>("useSystemVoice", default: false)
    static let speechVoice = Key<AVSpeechSynthesisVoice?>("SpeechVoice")
    static let speechVolume = Key<Float>("SpeechVolume", default: 1.0)
    static let speechRate = Key<Float>("SpeechRate", default: AVSpeechUtteranceDefaultSpeechRate)
    static let speechPitch = Key<Float>("SpeechPitch", default: 1.0)
    static let speechDelayBefore = Key<Double>("SpeechDelayBefore", default: 0)
    static let speechDelayAfter = Key<Double>("SpeechDelayAfter", default: 0)
    static let speechStopBoundary = Key<AVSpeechBoundary>("SpeechStopBoundary", default: .immediate)

//    static let useVoiceOverPronunciations = Key<Bool>("useVoiceOverPronunciations", default: false)
    static let pronunciations = Key<[Pronunciation]>("Pronunciations", default: [])
    static let selectionUnit = Key<Selection.Unit>("SelectionUnit", default: .sentence)
//    NOTE: can't use EasyReader.State as the Dictionary key for some reason
//    static let stateImageNames = Key<[EasyReader.State: String]>("StateImages", default: [
////        .stopped: "waveform",
//        .stopped: "waveform.slash",
////        .paused: "waveform",
////        .reading: "waveform",
//        .error: "waveform.badge.exclamationmark",
//    ])
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
