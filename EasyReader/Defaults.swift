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

//    static let useVoiceOverPronunciations = Key<Bool>("useVoiceOverPronunciations", default: false)
    static let pronunciations = Key<[Pronunciation]>("Pronunciations", default: [])
//    static let stopBoundary = Key<AVSpeechBoundary>("stopBoundary", default: .immediate)
//    static let selectUnit = Key<SelectUnit>("selectUnit", default: .sentence)
//    static let readerStateImageNames = Key<[EasyReader.State: String]>("readerStateImageNames", default: [
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

//TODO: Id or ID?
//struct VoicePrefs {
//    private static let voiceDefaults = UserDefaults(suiteName: "com.apple.speech.voice.prefs")
//    private static let voiceName = Defaults.Key<String>("SelectedVoiceName")
//    private static let selectedVoiceCreator = Defaults.Key<Int>("SelectedVoiceCreator")
//    private static let selectedVoiceID = Defaults.Key<Int>("SelectedVoiceID")
//    private static let voiceRateDataArray = Defaults.Key<[[Int]]>("VoiceRateDataArray")
//    private static let voiceOverDefaults = UserDefaults(suiteName: "com.apple.VoiceOver4/default")
//    private static let voiceOverVoiceId = Defaults.Key<String?>("SCRCategories_SCRCategorySystemWide_SCRSpeechLanguages_default_SCRSpeechComponentSettings_SCRVoiceIdentifier")
//
//    static func tryGetVoice() -> AVSpeechSynthesisVoice? {
//        if let voiceName = voiceDefaults?[voiceName] {
//            return AVSpeechSynthesisVoice.speechVoices().first(where: { $0.name == voiceName })
//        }
//        if let voiceId = voiceOverDefaults?[voiceOverVoiceId] {
//            return AVSpeechSynthesisVoice(identifier: voiceId)
//        }
//        return nil
//    }
//
//    static func tryGetSpeechRate(for voiceId: Int) -> Float? {
//        guard let voiceCreator = voiceDefaults?[selectedVoiceCreator],
//              let voiceID = voiceDefaults?[selectedVoiceID],
//              let voiceRates = voiceDefaults?[voiceRateDataArray],
//              let voiceRate = voiceRates.first(where: { $0[0] == voiceCreator && $0[1] == voiceID })?[2]
//        else { return nil }
////        NOTE: voice rate appears to be mapped from 90 to 360 with 180 being the default
//        return Float(voiceRate) / 360
//    }
//
//    static func tryGetPronunciations() -> [Pronunciation] {
//        var pronunciations: [Pronunciation] = []
////        let voiceOverPreferences = UserDefaults.standard.persistentDomain(forName: "com.apple.VoiceOver4/default")
////        for key in voiceOverPreferences.keys {
//////            NOTE: can't get default pronunciations because they use SCRSubTextKey instead of SCRSubText
////            guard key.starts(with: "custom.pronunciation"),
////                  let pronunciation = voiceOverPreferences[key] as? [String: String],
////                  let domainIdentifier = pronunciation["SCRDomainIdentifier"],
////                  let searchText = pronunciation["SCRSearchText"],
////                  let replaceText = pronunciation["SCRSubText"],
////                  pronunciation["SCREnabled"] == "1"
////            else { continue }
////            pronunciations.append(Pronunciation(
////                search: searchText,
////                replace: replaceText,
////                domain: domainIdentifier,
////                options: pronunciation["SCRIgnoreCase"] == "1" ? [.caseInsensitive] : []
////            ))
////        }
//        return pronunciations
//    }
//}

//private func setupVoiceSettings() {
//    guard let voicePreferences = UserDefaults.standard.persistentDomain(forName: "com.apple.speech.voice.prefs"),
//          let voiceName = voicePreferences["SelectedVoiceName"] as? String,
//          let voice = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.name == voiceName })
//    else { return }
////        speechVoice = nil
////        speechVoice = AVSpeechSynthesisVoice(identifier: NSSpeechSynthesizer.defaultVoice.rawValue)
////        speechVoice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
////        speechVoice = AVSpeechSynthesisVoice(language: "en-GB")
//
////        TODO: why are we creating a new voice from the identifier instead of just setting speechVoice to voice?
////        speechVoice = AVSpeechSynthesisVoice(identifier: voice.identifier)
//    speechVoice = voice
//    guard let voiceCreator = voicePreferences["SelectedVoiceCreator"] as? Int,
//          let voiceID = voicePreferences["SelectedVoiceID"] as? Int,
//          let voiceRates = voicePreferences["VoiceRateDataArray"] as? [[Int]],
//          let voiceRate = voiceRates.first(where: { $0[0] == voiceCreator && $0[1] == voiceID })?[2]
//    else { return }
////        NOTE: voice rate appears to be mapped from 90 to 360 with 180 being the default
//    rate = Float(voiceRate) / 360
//}
//
//private func setupPronunciationsAndMaybeVoice() {
//    guard let voiceOverPreferences = UserDefaults.standard.persistentDomain(forName: "com.apple.VoiceOver4/default") else { return }
//    if speechVoice == nil, let voiceIdentifier = voiceOverPreferences["SCRCategories_SCRCategorySystemWide_SCRSpeechLanguages_default_SCRSpeechComponentSettings_SCRVoiceIdentifier"] as? String {
//        speechVoice = AVSpeechSynthesisVoice(identifier: voiceIdentifier)
//    }
//    for key in voiceOverPreferences.keys {
////            NOTE: can't get default pronunciations because they use SCRSubTextKey instead of SCRSubText
//        guard key.starts(with: "custom.pronunciation"),
//              let pronunciation = voiceOverPreferences[key] as? [String: String],
//              let domainIdentifier = pronunciation["SCRDomainIdentifier"],
//              let searchText = pronunciation["SCRSearchText"],
//              let replaceText = pronunciation["SCRSubText"],
//              pronunciation["SCREnabled"] == "1"
//        else { continue }
//        pronunciations.append(Pronunciation(
//            search: searchText,
//            replace: replaceText,
//            domain: domainIdentifier,
//            options: pronunciation["SCRIgnoreCase"] == "1" ? [.caseInsensitive] : []
//        ))
//    }
//}
