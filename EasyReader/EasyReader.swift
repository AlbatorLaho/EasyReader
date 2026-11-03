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

final class EasyReader: NSObject {
    private var stopType: StopType = .none
    private(set) var state: State = .stopped {
        didSet {
            guard state != oldValue else { return }
            Log.reader.debug("state \(oldValue) → \(state)")
            delegate?.easyReader(self, didChangeState: state)
        }
    }
    /// A pause landed on the utterance's last word, so it finished instead of being cancelled;
    /// resuming continues with the next unit rather than re-reading the finished one.
    private var finishedWhilePausing = false

    private let synthesizer = AVSpeechSynthesizer()
    var textSelector: TextSelector?
    var readable: Readable? {
        didSet {
            guard readable !== oldValue else { return }
            oldValue?.onInvalidate = nil
            readable?.onInvalidate = { [weak self] in
                Log.reader.debug("readable invalidated, stopping")
                self?.stop()
                self?.readable = nil
            }
        }
    }
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
            Log.reader.debug("play(from: \(unit)): selection changed (\(String(describing: lastSelection)) → \(String(describing: readable?.selection))), reading selection")
            return ensureSelection() && readSelection()
        }
        if state == .paused, finishedWhilePausing {
            Log.reader.debug("play(from: \(unit)): utterance finished while pausing, continuing")
            return skip(.forward)
        }
        Log.reader.debug("play(from: \(unit)): resuming \(selection), last spoken range \(String(describing: lastReadRange))")
        switch unit {
            case .word: return readSelection(from: lastReadRange?.lowerBound)
            case .selection: return readSelection()
        }
    }

    @discardableResult
    func pause() -> Bool {
        guard synthesizer.isSpeaking else {
            Log.reader.debug("pause: not speaking")
            return false
        }
        Log.reader.debug("pause (stopType was \(stopType))")
        stopType = .pause
        return synthesizer.stopSpeaking(at: Defaults[.speechStopBoundary])
    }

    @discardableResult
    func stop() -> Bool {
        guard synthesizer.isSpeaking else {
            guard state == .paused else {
                Log.reader.debug("stop: not speaking or paused")
                return false
            }
            Log.reader.debug("stop: while paused")
            state = .stopped
            return true
        }
        Log.reader.debug("stop (stopType was \(stopType))")
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

    @discardableResult
    func skip(_ direction: Selection.Direction) -> Bool {
        guard select(direction) else {
            if direction == .backward {
                Log.reader.debug("skip(backward): at start, re-reading current selection")
                return ensureSelection() && readSelection()
            }
            Log.reader.debug("skip(\(direction)): nothing to select, stopping")
            return stop()
        }
        return readSelection()
    }

    func pronunciations(with domain: String?) -> [Pronunciation] {
        Defaults[.pronunciations].filter({ pronunciation in
            pronunciation.enabled && (pronunciation.domain == nil || pronunciation.domain == domain)
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
        Log.speech.debug(
            "speak \(string.utf16.count) chars (voice \(utterance.voice?.identifier ?? "default"), rate \(utterance.rate)): \(string.prefix(80).debugDescription)"
        )
        lastSelection = readable?.selection
        lastReadString = nil
        lastReadRange = nil
        finishedWhilePausing = false
        synthesizer.speak(utterance)
    }

    private func scroll(to selection: Selection) {
        guard Defaults[.scrollSelectionIntoView] else { return }
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
        else {
            Log.reader.debug("select(\(direction)): no text, selection, or selector")
            return false
        }
        Log.reader.debug("select(\(direction)): \(selection) → \(nextSelection) of \(fullText.utf16.count)")
        // Backward from the start: keep the current selection (forward keeps the empty end selection,
        // which `ensureSelection` uses to wrap around).
        guard direction == .forward || !nextSelection.isEmpty else { return false }
        readable?.selection = nextSelection
        scroll(to: nextSelection)
        return !nextSelection.isEmpty
    }

    private func ensureSelection() -> Bool {
        guard let fullText = readable?.fullText, let selection = readable?.selection else {
            Log.reader.debug("ensureSelection: no text or selection")
            return false
        }
        guard selection.startIndex(in: fullText) != fullText.endIndex else {
            Log.reader.debug("ensureSelection: selection at end of text, wrapping to start")
            readable?.selection = Selection()
            return select(.forward)
        }
        guard !selection.isEmpty else {
            Log.reader.debug("ensureSelection: empty selection at \(selection.lowerBound), selecting next unit")
            return select(.forward)
        }
        return true
    }

    private func readSelection(from index: Int? = nil) -> Bool {
        guard var selectedText = readable?.selectedText else {
            Log.reader.debug("readSelection: no selected text")
            return false
        }
        let pronunciations = pronunciations(with: readable?.appDomain)
        if !pronunciations.isEmpty {
            Log.reader.debug("applying \(pronunciations.count) pronunciation(s) for \(readable?.appDomain ?? "any app")")
        }
        for pronunciation in pronunciations {
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
                Log.reader.debug("resuming from offset \(index)")
            }
        }
        if synthesizer.isSpeaking {
            Log.reader.debug("interrupting current utterance (stopType was \(stopType))")
            stopType = .willContinue
            synthesizer.stopSpeaking(at: .immediate)
        }
        read(string: selectedText)
        return true
    }
}

extension EasyReader: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Log.speech.debug("didStart")
        state = .reading
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Log.speech.debug("didFinish (stopType \(stopType))")
        if stopType == .pause {
            finishedWhilePausing = true
        }
        guard stopType == .none,
              let selection = readable?.selection,
              !selection.isEmpty,
              skip(.forward)
        else {
            if stopType == .none {
                stopType = .cancel
            }
            speechSynthesizer(synthesizer, didCancel: utterance)
            return
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Log.speech.debug("didCancel (stopType \(stopType))")
        switch stopType {
            case .none: break
            case .willContinue: break
            case .pause: state = .paused
            case .cancel: state = .stopped
        }
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
        case willContinue
        case pause
        case cancel
    }

    enum State {
        case reading
        case paused
        case stopped
    }

    enum ResumeUnit: String, Defaults.Serializable {
        case word
        case selection
    }
}

extension EasyReader {
    enum ReadTarget {
        case element(UIElement, fromFocused: Bool = false)
        case app(NSRunningApplication?)

        static var systemWideElement: Self { .element(AXSwift.systemWideElement, fromFocused: true) }
        static var currentApp: Self { .app(NSRunningApplication.current) }
        static var frontmostApp: Self { .app(NSWorkspace.shared.frontmostApplication) }
    }

    func start(reading readable: Readable) -> Bool {
        Log.reader.debug("start reading \(type(of: readable)) in \(readable.appDomain ?? "unknown app")")
        self.readable = readable
        return play(from: .selection)
    }

    func start(reading target: ReadTarget) -> Bool {
        switch target {
            case .element(let element, let fromFocused):
                return start(reading: element, fromFocused: fromFocused)
            case .app(let app):
                guard let app, let element = Application(app) else { return false }
                return start(reading: element, fromFocused: true)
        }
    }

    private func start(reading element: UIElement, fromFocused: Bool) -> Bool {
        if NSRunningApplication.current.processIdentifier != (try? element.pid()) {
            guard UIElement.isProcessTrusted(withPrompt: true) else {
                Log.accessibility.error("No accessibility API permission.")
                return false
            }
        }
        guard let focusedElement: UIElement = (fromFocused ? try? element.attribute(.focusedUIElement) : element) else {
            Log.accessibility.error("Unable to get focused element.")
            return false
        }
        guard let readableElement = findReadableElement(from: focusedElement) else {
            Log.accessibility.error("Unable to find readable element.")
            return false
        }
        return start(reading: readableElement)
    }

//    FIXME: text area's frame size seems to get messed up, if the first time this is run, it isn't the focused element
    /// BFS over children and parents, staying inside the starting element's window
    /// (never climbing to the window's parent, the application) and visiting at most `limit` elements.
    private func findReadableElement(from element: UIElement, limit: Int = 1000) -> ReadableElement? {
        var queue: [UIElement] = [element]
        var visited: Set<UIElement> = [element]

        while !queue.isEmpty, visited.count <= limit {
            let current = queue.removeFirst()

            if let readable = try? current.readableElement() {
                Log.accessibility.debug("found \(type(of: readable)) after visiting \(visited.count) element(s)")
                try? current.setAttribute(.focused, value: true)
                return readable
            }

            let role = try? current.role()
            Log.accessibility.debug("visiting \(role?.rawValue ?? "unknown role")")
            // Not every app supports navigation order (AppKit does).
            let children: [UIElement]? =
                (try? current.arrayAttribute(.childrenInNavigationOrder)) ?? (try? current.arrayAttribute(.children))
            for child in children ?? [] where !visited.contains(child) {
                visited.insert(child)
                queue.append(child)
            }

            guard role != .window, role != .application else { continue }
            if let parent: UIElement = try? current.attribute(.parent), !visited.contains(parent) {
                visited.insert(parent)
                queue.append(parent)
            }
        }

        Log.accessibility.debug("no readable element after visiting \(visited.count) element(s)")
        return nil
    }
}
