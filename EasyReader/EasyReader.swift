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

@MainActor
protocol EasyReaderDelegate: AnyObject {
    func easyReader(_ reader: EasyReader, didChangeState state: EasyReader.State)
}

@MainActor
final class EasyReader: NSObject {
    private var stopType: StopType = .none
    private(set) var state: State = .stopped {
        didSet {
            guard state != oldValue else { return }
            Log.reader.debug("state \(oldValue) → \(state)")
            if state == .stopped { readable?.endReading() }
            delegate?.easyReader(self, didChangeState: state)
        }
    }

    private let synthesizer = AVSpeechSynthesizer()
    /// Utterance handed to the synthesizer and not yet finished/cancelled. Unlike `isSpeaking`,
    /// it covers the gap between `speak` and `didStart`.
    private var currentUtterance: AVSpeechUtterance?
    private var isSpeaking: Bool { synthesizer.isSpeaking || currentUtterance != nil }
    var textSelector: TextSelector?
    var readable: Readable? {
        didSet {
            guard readable !== oldValue else { return }
            oldValue?.endReading()
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
    /// Waits for a Chromium app to build its page content (`startAfterEnablingWebContent`).
    private var pendingStart: Task<Void, Never>?

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
        readable?.beginReading()
        let started = resume(from: unit)
        if !started, state == .stopped { readable?.endReading() }
        return started
    }

    private func resume(from unit: ResumeUnit) -> Bool {
        guard let selection = readable?.selection, lastSelection == selection else {
            Log.reader.debug("play(from: \(unit)): selection changed (\(String(describing: lastSelection)) → \(String(describing: readable?.selection))), reading selection")
            return ensureSelection() && readSelection()
        }
        Log.reader.debug("play(from: \(unit)): resuming \(selection), last spoken range \(String(describing: lastReadRange))")
        switch unit {
            case .word: return readSelection(from: lastReadRange?.lowerBound)
            case .selection: return readSelection()
        }
    }

    /// Undoes changes the readable made to its app (see `Readable.endReading`) before the app quits.
    func prepareForTermination() {
        readable?.endReading()
    }

    @discardableResult
    func pause() -> Bool {
        guard isSpeaking else {
            Log.reader.debug("pause: not speaking")
            return false
        }
        Log.reader.debug("pause (stopType was \(stopType))")
        stopType = .pause
        return synthesizer.stopSpeaking(at: Defaults[.speechStopBoundary])
    }

    @discardableResult
    func stop() -> Bool {
        pendingStart?.cancel()
        pendingStart = nil
        guard isSpeaking else {
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

    /// User-initiated skip. Forward on the last unit does nothing (see `canSkipForward`);
    /// reaching the end on its own still stops (`advance`).
    @discardableResult
    func skip(_ direction: Selection.Direction) -> Bool {
        if direction == .forward, !canSkipForward {
            Log.reader.debug("skip(forward): at last unit, ignoring")
            return false
        }
        return advance(direction)
    }

    /// Whether a unit follows the current selection.
    var canSkipForward: Bool {
        nextSelection(.forward).map { !$0.isEmpty } ?? false
    }

    /// Selects and reads the next unit; stops when there is none forward.
    @discardableResult
    private func advance(_ direction: Selection.Direction) -> Bool {
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
        currentUtterance = utterance
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

    private func nextSelection(_ direction: Selection.Direction) -> Selection? {
        guard let readable,
              let fullText = readable.fullText,
              let selection = readable.selection,
              let nextSelection = textSelector?.select(direction, from: selection, in: fullText, blocks: { readable.textBlock(containing: $0) })
        else {
            Log.reader.debug("nextSelection(\(direction)): no text, selection, or selector")
            return nil
        }
        Log.reader.debug("nextSelection(\(direction)): \(selection) → \(nextSelection) of \(fullText.utf16.count)")
        return nextSelection
    }

    private func select(_ direction: Selection.Direction) -> Bool {
        guard let nextSelection = nextSelection(direction) else { return false }
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
        if isSpeaking {
            Log.reader.debug("interrupting current utterance (stopType was \(stopType))")
            stopType = .willContinue
            synthesizer.stopSpeaking(at: .immediate)
        }
        read(string: selectedText)
        return true
    }
}

// AVSpeechSynthesizer calls its delegate on the main thread; `@preconcurrency` checks that at runtime.
extension EasyReader: @preconcurrency AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Log.speech.debug("didStart")
        state = .reading
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Log.speech.debug("didFinish (stopType \(stopType))")
        if utterance === currentUtterance { currentUtterance = nil }
        // macOS reports `didFinish` (not `didCancel`) for `stopSpeaking` too. With the word boundary it
        // first fires `willSpeakRange` for the word it stops *before* (unspoken), so whether the last word
        // was spoken can't be told; resuming re-reads from that word rather than risk skipping text.
        guard stopType == .none,
              let selection = readable?.selection,
              !selection.isEmpty,
              advance(.forward)
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
        if utterance === currentUtterance { currentUtterance = nil }
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

        static var frontmostApp: Self { .app(NSWorkspace.shared.frontmostApplication) }
    }

    /// While paused, starting the same element resumes it; any other element starts fresh.
    func start(reading readable: Readable) -> Bool {
        if state == .paused, let current = self.readable, Self.isSameTarget(current, readable) {
            Log.reader.debug("start: resuming paused \(type(of: readable))")
            return play(from: Defaults[.resumeUnit])
        }
        Log.reader.debug("start reading \(type(of: readable)) in \(readable.appDomain ?? "unknown app")")
        if state == .paused {
            state = .stopped
        }
        self.readable = readable
        return play(from: .selection)
    }

    private static func isSameTarget(_ lhs: Readable, _ rhs: Readable) -> Bool {
        if lhs === rhs { return true }
        guard let lhs = lhs as? ReadableElement, let rhs = rhs as? ReadableElement else { return false }
        return lhs.handle == rhs.handle
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
            if let pid = try? element.pid(), let app = NSRunningApplication(processIdentifier: pid), WebAccessibility.isChromium(app) {
                return startAfterEnablingWebContent(reading: element, fromFocused: fromFocused, pid: pid)
            }
            Log.accessibility.error("Unable to find readable element.")
            return false
        }
        return start(reading: readableElement)
    }

    /// A Chromium app vends no page content until its AX mode is on (see `WebAccessibility`): turns it on, then retries
    /// for a few seconds while Chromium builds its AX tree (it beeps if that fails).
    private func startAfterEnablingWebContent(reading element: UIElement, fromFocused: Bool, pid: pid_t) -> Bool {
        let flags = WebAccessibility.enable(pid: pid)
        guard !flags.isEmpty else {
            Log.accessibility.error("Unable to find readable element.")
            return false
        }
        Log.accessibility.debug("turned on \(flags); waiting for page content")
        pendingStart?.cancel()
        pendingStart = Task { @MainActor [weak self] in
            for _ in 0..<50 {
                guard (try? await Task.sleep(nanoseconds: 100_000_000)) != nil, let self else { break }
                let focused: UIElement? = fromFocused ? try? element.attribute(.focusedUIElement) : element
                guard let focused, let readable = self.findReadableElement(from: focused) else { continue }
                if let webArea = readable as? WebAreaReadableElement {
                    webArea.adoptAppFlags(flags)
                } else {
                    WebAccessibility.restore(flags, pid: pid)
                }
                self.pendingStart = nil
                if !self.start(reading: readable) { NSSound.beep() }
                return
            }
            WebAccessibility.restore(flags, pid: pid)
            if !Task.isCancelled {
                Log.accessibility.error("Unable to find readable element.")
                NSSound.beep()
            }
        }
        return true
    }

    /// BFS over children and parents, staying inside the starting element's window
    /// (never climbing to the window's parent, the application) and visiting at most `limit` elements.
    private func findReadableElement(from element: UIElement, limit: Int = 1000) -> ReadableElement? {
        // Focus is often deep inside a readable element (e.g. a link in a web page, whose BFS would fan out over the
        // page before climbing to its web area), so check the ancestors right after the element itself (a focused
        // text area in a web page is read, not the page).
        if (try? element.readableElement()) == nil, let readable = readableAncestor(of: element) {
            try? readable.handle.setAttribute(.focused, value: true)
            return readable
        }
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

    /// The nearest readable ancestor below the window (the starting element itself is left to the BFS).
    private func readableAncestor(of element: UIElement) -> ReadableElement? {
        var current = element
        for _ in 0..<100 {
            guard let parent: UIElement = try? current.attribute(.parent),
                let role = try? parent.role(), role != .window, role != .application
            else { return nil }
            if let readable = try? parent.readableElement() {
                Log.accessibility.debug("found \(type(of: readable)) as an ancestor of the focused element")
                return readable
            }
            current = parent
        }
        return nil
    }
}
