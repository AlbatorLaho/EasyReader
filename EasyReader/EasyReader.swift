//
//  EasyReader.swift
//  EasyReader
//
//  Created by Ewalk on 24/11/3.
//

import Foundation
import AVKit
import AXSwift
import Defaults

protocol EasyReaderDelegate: AnyObject {
    func easyReader(_ reader: EasyReader, didChangeState state: EasyReader.State)
}

//FIXME: won't properly stop/resume if paused at the end of reading
final class EasyReader: NSObject {
    private var shouldStop = true
    private(set) var state: State = .stopped {
        didSet {
            guard state != oldValue else { return }
//            print("state: \(state)")
            delegate?.easyReader(self, didChangeState: state)
//            if state == .stopped {
//                readable = nil
//            }
        }
    }
    
    private let synthesizer = AVSpeechSynthesizer()
    private var utterance: AVSpeechUtterance?
//    var voice: AVSpeechSynthesisVoice?
    var rate: Float? { utterance?.rate }
////    private let defaultPronunciations: [Pronunciation] = []
//    var pronunciations: [Pronunciation] = []
    var textSelector: TextSelector?
    var readable: Readable?
    weak var delegate: EasyReaderDelegate?
    
    override init() {
        super.init()
        synthesizer.delegate = self
//        setupVoiceSettings()
//        setupPronunciationsAndMaybeVoice()
//        print(AVSpeechUtteranceDefaultSpeechRate)
//        print(AVSpeechUtteranceMinimumSpeechRate)
//        print(AVSpeechUtteranceMaximumSpeechRate)
//        print(NSSpeechSynthesizer.defaultVoice.rawValue)
//        print(AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())?.identifier)
    }
    
//    private func setupVoiceSettings() {
//        guard let voicePreferences = UserDefaults.standard.persistentDomain(forName: "com.apple.speech.voice.prefs"),
//              let voiceName = voicePreferences["SelectedVoiceName"] as? String,
//              let voice = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.name == voiceName })
//        else { return }
////        voice = nil
////        voice = AVSpeechSynthesisVoice(identifier: NSSpeechSynthesizer.defaultVoice.rawValue)
////        voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
////        voice = AVSpeechSynthesisVoice(language: "en-GB")
//
////        TODO: why are we creating a new voice from the identifier instead of just setting voice to voice?
////        voice = AVSpeechSynthesisVoice(identifier: voice.identifier)
//        voice = voice
//        guard let voiceCreator = voicePreferences["SelectedVoiceCreator"] as? Int,
//              let voiceID = voicePreferences["SelectedVoiceID"] as? Int,
//              let voiceRates = voicePreferences["VoiceRateDataArray"] as? [[Int]],
//              let voiceRate = voiceRates.first(where: { $0[0] == voiceCreator && $0[1] == voiceID })?[2]
//        else { return }
////        NOTE: voice rate appears to be mapped from 90 to 360 with 180 being the default
//        rate = Float(voiceRate) / 360
//    }
//
//    private func setupPronunciationsAndMaybeVoice() {
//        guard let voiceOverPreferences = UserDefaults.standard.persistentDomain(forName: "com.apple.VoiceOver4/default") else { return }
//        if voice == nil, let voiceIdentifier = voiceOverPreferences["SCRCategories_SCRCategorySystemWide_SCRSpeechLanguages_default_SCRSpeechComponentSettings_SCRVoiceIdentifier"] as? String {
//            voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier)
//        }
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
////                ignoreCase: pronunciation["SCRIgnoreCase"] == "1"
//////                enabled: pronunciation["SCREnabled"] == "1"
////            ))
////        }
//    }
    
    
    
    func setReadableElement(from app: NSRunningApplication) -> Bool {
        guard let focusedElement: UIElement = try? Application(app)?.attribute(.focusedUIElement) else { return false }
        return setReadableElement(focusedElement)
    }
    
    func setReadableElement(_ element: UIElement) -> Bool {
//        TODO: do I have to make sure this is run on the main thread?
//        FIXME: for some reason, this isn't showing the prompt anymore...
//        guard UIElement.isProcessTrusted(withPrompt: true) else {
//            NSLog("No accessibility API permission")
//            return false
//        }
        guard let role: String = try? element.attribute(.role) else {
            NSLog("Unable to get element role.")
            return false
        }
        guard let readableType = ReadableElement[.init(role)] else {
            NSLog("Unsupported readable element role: \(role)")
            return false
        }
        readable = readableType.init(element)
        return true
    }
    
    
    
    private func select(_ direction: Selection.Direction) -> Bool {
        guard let fullText = readable?.fullText,
              let selection = readable?.selection,
              let nextSelection = textSelector?.select(direction, from: selection, in: fullText)
        else { return false }
        readable?.selection = nextSelection
        readable?.scroll(to: nextSelection)
        return !nextSelection.isEmpty
    }
    
    private func ensureSelection() -> Bool {
        guard let fullText = readable?.fullText, let selection = readable?.selection else { return false }
        guard selection.startIndex(in: fullText) != fullText.endIndex else {
            readable?.selection = Selection()
            return select(.forward)
        }
        guard !selection.isEmpty else {
            return select(.forward)
        }
        return true
    }
    
    private func readSelection() -> Bool {
        guard var selectedText = readable?.selectedText else { return false }
        for pronunciation in Defaults[.pronunciations].filter({ $0.domain == nil || $0.domain == readable?.appDomain }) {
            selectedText = selectedText.replacingOccurrences(
                of: pronunciation.search,
                with: pronunciation.replace,
                options: pronunciation.options
            )
        }
//        print("reading: \(selectedText)")
        let utterance = AVSpeechUtterance(string: selectedText)
        self.utterance = utterance
//        NOTE: appears to have no affect
        utterance.prefersAssistiveTechnologySettings = true
        utterance.voice = Defaults[.speechVoice]
        utterance.volume = Defaults[.speechVolume]
        utterance.rate = Defaults[.speechRate]
        utterance.pitchMultiplier = Defaults[.speechPitch]
        utterance.preUtteranceDelay = Defaults[.speechDelayBefore]
        utterance.postUtteranceDelay = Defaults[.speechDelayAfter]
        if synthesizer.isSpeaking {
            shouldStop = false
            synthesizer.stopSpeaking(at: Defaults[.speechStopBoundary])
        }
        synthesizer.speak(utterance)
        return true
    }
    
    
    
//    TODO: rename to something better
    func startReadingFrontmostApplication() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication, setReadableElement(from: app) else { return false }
        return start()
    }
    
    func start() -> Bool {
        guard state == .stopped, ensureSelection() else { return false }
        return readSelection()
    }
    
    func stop() -> Bool {
        guard state != .stopped else { return false }
        return synthesizer.stopSpeaking(at: Defaults[.speechStopBoundary])
    }
    
    func pause() -> Bool {
        guard state == .reading else { return false }
        return synthesizer.pauseSpeaking(at: Defaults[.speechStopBoundary])
    }
    
//    TODO: should have option to either resume from last word, or restart from begining of selection
//    TODO: check if selection has changed, if so, don't resume, start over?
   func resume() -> Bool {
        guard state == .paused else { return false }
        return synthesizer.continueSpeaking()
    }
    
    func togglePauseResume() -> Bool {
        switch state {
            case .reading: return pause()
            case .paused: return resume()
            default: return false
        }
    }
    
//    TODO: should restart reading if selection location is 0 for backward?
    func skip(_ direction: Selection.Direction) -> Bool {
        guard select(direction) else { return stop() }
        return readSelection()
    }
}

extension EasyReader: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        state = .reading
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard let selection = readable?.selection,
              !selection.isEmpty,
              skip(.forward)
        else {
            state = .stopped
            return
        }
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
        state = .paused
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
        state = .reading
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        guard shouldStop else {
            shouldStop = true
            return
        }
        state = .stopped
    }
}

extension EasyReader {
    enum State {
        case stopped
        case reading
        case paused
        case error
    }
}
