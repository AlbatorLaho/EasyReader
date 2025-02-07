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
    private var stopType: StopType = .none
    private(set) var state: State = .stopped {
        didSet {
            guard state != oldValue else { return }
            delegate?.easyReader(self, didChangeState: state)
        }
    }

    private let synthesizer = AVSpeechSynthesizer()
    var textSelector: TextSelector?
    var readable: Readable?
    weak var delegate: EasyReaderDelegate?
    private var lastSelection: Selection?
    private var lastReadString: String?
    private var lastReadRange: NSRange?

    override init() {
        super.init()
        synthesizer.delegate = self
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



    @discardableResult
    func play(from unit: ResumeUnit) -> Bool {
        guard let selection = readable?.selection, lastSelection == selection else {
            return ensureSelection() && readSelection()
        }
        switch unit {
            case .word: return readSelection(from: lastReadRange?.lowerBound)
            case .selection: return readSelection()
        }
    }

    @discardableResult
    func pause() -> Bool {
        guard state == .reading else { return false }
        return synthesizer.pauseSpeaking(at: Defaults[.speechStopBoundary])
    }

    @discardableResult
    func stop() -> Bool {
        guard state != .stopped else { return false }
        stopType = .cancel
        return synthesizer.stopSpeaking(at: Defaults[.speechStopBoundary])
    }

    @discardableResult
    func togglePlayPause() -> Bool {
        switch state {
            case .reading: return pause()
            case .paused: return play(from: Defaults[.resumeUnit])
            case .stopped: return play(from: .selection)
        }
    }

//    TODO: should restart reading if selection location is 0 for backward?
    @discardableResult
    func skip(_ direction: Selection.Direction) -> Bool {
        guard select(direction) else { return stop() }
        return readSelection()
    }



    private func pronunciations(with domain: String?) -> [Pronunciation] {
        Defaults[.pronunciations].filter({ pronunciation in
            pronunciation.domain == nil || pronunciation.domain == domain
        })
    }

    private func read(string: String) {
        let utterance = AVSpeechUtterance(string: string)
        utterance.voice = Defaults[.speechVoice]
        utterance.volume = Defaults[.speechVolume]
        utterance.rate = Defaults[.speechRate]
        utterance.pitchMultiplier = Defaults[.speechPitch]
        utterance.preUtteranceDelay = Defaults[.speechDelayBefore]
        utterance.postUtteranceDelay = Defaults[.speechDelayAfter]
        lastSelection = readable?.selection
        lastReadString = nil
        lastReadRange = nil
        synthesizer.speak(utterance)
    }

    private func scroll(to selection: Selection) {
        readable?.scroll(to: selection, options: ScrollOptions(
            padding: Defaults[.scrollPadding],
            smooth: Defaults[.scrollSmooth],
            duration: Defaults[.scrollDuration],
            updateRate: Defaults[.scrollUpdateRate]
        ))
    }

    private func select(_ direction: Selection.Direction) -> Bool {
        guard let fullText = readable?.fullText,
              let selection = readable?.selection,
              let nextSelection = textSelector?.select(direction, from: selection, in: fullText)
        else { return false }
        readable?.selection = nextSelection
        scroll(to: nextSelection)
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

    private func readSelection(from index: Int? = nil) -> Bool {
        guard var selectedText = readable?.selectedText else { return false }
        for pronunciation in pronunciations(with: readable?.appDomain) {
            selectedText = selectedText.replacingOccurrences(
                of: pronunciation.search,
                with: pronunciation.replace,
                options: pronunciation.options
            )
        }
        if let index, let lastReadString, let lastReadStringRange = selectedText.range(of: lastReadString, options: [.anchored, .backwards]) {
            let lastRange = NSRange(lastReadStringRange, in: selectedText)
            let newRange = NSRange(index + lastRange.lowerBound..<lastRange.upperBound)
            if let range = Range(newRange, in: selectedText) {
                selectedText = String(selectedText[range])
            }
        }
        if synthesizer.isSpeaking {
            stopType = .stop
            synthesizer.stopSpeaking(at: .immediate)
        }
        read(string: selectedText)
        return true
    }
}

extension EasyReader: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        state = .reading
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard stopType == .none,
              let selection = readable?.selection,
              !selection.isEmpty,
              skip(.forward)
        else {
            if stopType == .cancel {
                speechSynthesizer(synthesizer, didCancel: utterance)
            } else {
                state = .stopped
                stopType = .none
            }
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
        guard stopType == .cancel else { return }
        state = .stopped
        stopType = .none
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        lastReadString = utterance.speechString
        lastReadRange = characterRange
    }
}

extension EasyReader {
    enum StopType {
        case none
        case stop
        case cancel
    }

    enum State {
        case stopped
        case paused
        case reading
    }

    enum ResumeUnit: String, Defaults.Serializable {
        case word
        case selection
    }
}

extension EasyReader {
    enum ReadTarget {
        case element(UIElement, useFocusedElement: Bool = false)
        case app(NSRunningApplication?)

        static var systemWideElement: Self { .element(AXSwift.systemWideElement, useFocusedElement: true) }
        static var currentApp: Self { .app(NSRunningApplication.current) }
        static var frontmostApp: Self { .app(NSWorkspace.shared.frontmostApplication) }
    }

    func start(reading readable: Readable) -> Bool {
        self.readable = readable
        return play(from: .selection)
    }

    func start(reading target: ReadTarget) -> Bool {
        switch target {
            case .element(let element, let useFocusedElement):
                return start(reading: element, useFocusedElement: useFocusedElement)
            case .app(let app):
                guard let app, let element = Application(app) else { return false }
                return start(reading: element, useFocusedElement: true)
        }
    }

//    TODO: make a "smart" crawler to find readable elements
    private func start(reading element: UIElement, useFocusedElement: Bool) -> Bool {
        if NSRunningApplication.current.processIdentifier != (try? element.pid()) {
            guard UIElement.isProcessTrusted(withPrompt: true) else {
                NSLog("No accessibility API permission.")
                return false
            }
        }
        guard let focusedElement: UIElement = (useFocusedElement ? try? element.attribute(.focusedUIElement) : element) else {
            NSLog("Unable to get focused element.")
            return false
        }
        guard let readableElement = try? focusedElement.readableElement() else {
            NSLog("Unable to get readable element.")
            return false
        }
        return start(reading: readableElement)
    }
}
