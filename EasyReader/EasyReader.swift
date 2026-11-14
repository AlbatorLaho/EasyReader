import Foundation
import AVKit
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
    // Unlike `synthesizer.isSpeaking`, also covers the gap between `speak` and `didStart`.
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
    // Before pronunciations are applied.
    private var readText: String?
    private var utteranceOffset = 0
    private(set) var spokenText: SpokenText?
    private var lastReadOffset: Int?
    private var pendingStart: Task<Void, Never>?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    @discardableResult
    func play(from unit: ResumeUnit) -> Bool {
        readable?.beginReading()
        let started = resume(from: unit)
        if !started, state == .stopped { readable?.endReading() }
        return started
    }

    private func resume(from unit: ResumeUnit) -> Bool {
        guard let selection = readable?.selection, lastSelection == selection else {
            Log.reader.debug(
                "play(from: \(unit)): selection changed (\(String(describing: lastSelection)) → \(String(describing: readable?.selection))), reading selection")
            return ensureSelection() && readSelection()
        }
        Log.reader.debug("play(from: \(unit)): resuming \(selection), last spoken offset \(String(describing: lastReadOffset))")
        scroll(to: selection)
        switch unit {
            case .word: return readSelection(from: lastReadOffset)
            case .selection: return readSelection()
        }
    }

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

    /// Forward on the last unit does nothing; reaching the end on its own still stops (`advance`).
    @discardableResult
    func skip(_ direction: Selection.Direction) -> Bool {
        if direction == .forward, !canSkipForward {
            Log.reader.debug("skip(forward): at last unit, ignoring")
            return false
        }
        return advance(direction)
    }

    var canSkipForward: Bool {
        nextSelection(.forward).map { !$0.isEmpty } ?? false
    }

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

    func pronunciations(with appDomain: String?) -> [Pronunciation] {
        Defaults[.pronunciations].filter { pronunciation in
            pronunciation.enabled && (pronunciation.appDomain == nil || pronunciation.appDomain == appDomain)
        }
    }

    private func read(_ spoken: SpokenText) {
        let utterance =
            spoken.hasPhonetics
            ? AVSpeechUtterance(attributedString: spoken.attributedText)
            : AVSpeechUtterance(string: spoken.text)
        utterance.voice = Defaults[.speechVoice]
        utterance.volume = Defaults[.speechVolume]
        utterance.rate = Defaults[.speechRate]
        utterance.pitchMultiplier = Defaults[.speechPitch]
        utterance.preUtteranceDelay = Defaults[.speechDelayBefore]
        utterance.postUtteranceDelay = Defaults[.speechDelayAfter]
        Log.speech.debug(
            "speak \(spoken.text.utf16.count) chars (voice \(utterance.voice?.identifier ?? "default"), rate \(utterance.rate)): \(spoken.text.prefix(80).debugDescription)"
        )
        lastSelection = readable?.selection
        spokenText = spoken
        lastReadOffset = nil
        currentUtterance = utterance
        synthesizer.speak(utterance)
    }

    private func scroll(to selection: Selection) {
        guard Defaults[.scrollSelectionIntoView] else { return }
        readable?.scroll(
            to: selection,
            options: ScrollOptions(
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
        // Forward keeps the empty end selection: `ensureSelection` wraps around from it.
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
        scroll(to: selection)
        return true
    }

    /// From `offset` (in the original selected text) only if it's still the text last read.
    private func readSelection(from offset: Int? = nil) -> Bool {
        guard let selectedText = readable?.selectedText else {
            Log.reader.debug("readSelection: no selected text")
            return false
        }
        let pronunciations = pronunciations(with: readable?.appDomain)
        if !pronunciations.isEmpty {
            Log.reader.debug("applying \(pronunciations.count) pronunciation(s) for \(readable?.appDomain ?? "any app")")
        }
        var start = 0
        var text = selectedText
        if let offset, selectedText == readText,
            let index = Range(NSRange(location: offset, length: 0), in: selectedText)?.lowerBound
        {
            start = offset
            text = String(selectedText[index...])
            Log.reader.debug("resuming from offset \(offset)")
        }
        readText = selectedText
        utteranceOffset = start
        let spoken = SpokenText(text, applying: pronunciations)
        if isSpeaking {
            Log.reader.debug("interrupting current utterance (stopType was \(stopType))")
            stopType = .willContinue
            synthesizer.stopSpeaking(at: .immediate)
        }
        read(spoken)
        return true
    }
}

// Called on main; `@preconcurrency` checks that at runtime.
extension EasyReader: @preconcurrency AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Log.speech.debug("didStart")
        state = .reading
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Log.speech.debug("didFinish (stopType \(stopType))")
        if utterance === currentUtterance { currentUtterance = nil }
        // macOS reports `didFinish` for `stopSpeaking` too, hence the `stopType` check.
        guard stopType == .none,
            let selection = readable?.selection,
            !selection.isEmpty,
            advance(.forward)
        else {
            if stopType == .none { stopType = .cancel }
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
        guard utterance === currentUtterance, let spokenText else { return }
        let offset = utteranceOffset + spokenText.originalOffset(forSpoken: characterRange.location)
        // A word-boundary stop reports the unspoken word it stops before, so resuming there skips nothing.
        lastReadOffset = offset
        if let piece = readable?.didReach(offset) { scroll(to: piece) }
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
        case element(AXElement, fromFocused: Bool = false)
        case app(NSRunningApplication?)

        static var frontmostApp: Self { .app(NSWorkspace.shared.frontmostApplication) }
    }

    /// While paused, starting the same target resumes it.
    func start(reading readable: Readable) -> Bool {
        if state == .paused, let current = self.readable, Self.isSameTarget(current, readable) {
            Log.reader.debug("start: resuming paused \(type(of: readable))")
            return play(from: Defaults[.resumeUnit])
        }
        Log.reader.debug("start reading \(type(of: readable)) in \(readable.appDomain ?? "unknown app")")
        if state == .paused { state = .stopped }
        self.readable = readable
        return play(from: .selection)
    }

    private static func isSameTarget(_ lhs: Readable, _ rhs: Readable) -> Bool {
        if lhs === rhs { return true }
        if let lhs = lhs as? SelectedTextReadable, let rhs = rhs as? SelectedTextReadable {
            return lhs.app == rhs.app && lhs.fullText == rhs.fullText
        }
        guard let lhs = lhs as? ReadableElement, let rhs = rhs as? ReadableElement else { return false }
        return lhs.handle == rhs.handle
    }

    func start(reading target: ReadTarget) -> Bool {
        switch target {
            case .element(let element, let fromFocused):
                return start(reading: element, fromFocused: fromFocused)
            case .app(let app):
                guard let app else { return false }
                return start(reading: .application(pid: app.processIdentifier), fromFocused: true)
        }
    }

    private func start(reading element: AXElement, fromFocused: Bool) -> Bool {
        if NSRunningApplication.current.processIdentifier != (try? element.pid()) {
            guard AXElement.isProcessTrusted(prompt: true) else {
                Log.accessibility.error("No accessibility API permission.")
                return false
            }
        }
        let focusedElement = fromFocused ? try? element.attribute(.focusedUIElement) : element
        guard let focusedElement, let readableElement = findReadableElement(from: focusedElement) else {
            if focusedElement != nil, let pid = try? element.pid(), let app = NSRunningApplication(processIdentifier: pid),
                WebAccessibility.isChromium(app)
            {
                return startAfterEnablingWebContent(reading: element, fromFocused: fromFocused, pid: pid)
            }
            if let fallback = selectedTextFallback(in: element, focused: focusedElement) {
                return start(reading: fallback)
            }
            Log.accessibility.error(focusedElement == nil ? "Unable to get focused element." : "Unable to find readable element.")
            return false
        }
        return start(reading: readableElement)
    }

    // Chromium vends no page content until its AX mode is on; retry while it builds the tree.
    private func startAfterEnablingWebContent(reading element: AXElement, fromFocused: Bool, pid: pid_t) -> Bool {
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
                let focused = fromFocused ? try? element.attribute(.focusedUIElement) : element
                guard let focused, let readable = findReadableElement(from: focused) else { continue }
                if let webArea = readable as? WebAreaReadableElement {
                    webArea.adoptAppFlags(flags)
                } else {
                    WebAccessibility.restore(flags, pid: pid)
                }
                pendingStart = nil
                if !start(reading: readable) { NSSound.beep() }
                return
            }
            WebAccessibility.restore(flags, pid: pid)
            if !Task.isCancelled {
                let focused = fromFocused ? try? element.attribute(.focusedUIElement) : element
                if let fallback = self?.selectedTextFallback(in: element, focused: focused) {
                    if self?.start(reading: fallback) != true { NSSound.beep() }
                    return
                }
                Log.accessibility.error("Unable to find readable element.")
                NSSound.beep()
            }
        }
        return true
    }

    private func selectedTextFallback(in element: AXElement, focused: AXElement?) -> SelectedTextReadable? {
        guard let pid = try? element.pid() else { return nil }
        return SelectedTextReadable.selection(in: pid, focused: focused)
    }

    /// BFS over children and parents, never climbing past the window.
    private func findReadableElement(from element: AXElement, limit: Int = 1000) -> ReadableElement? {
        // Focus is often deep inside one (a link in a web page): climb before the BFS fans out over the page.
        if (try? element.readableElement()) == nil, let readable = readableAncestor(of: element) {
            try? readable.handle.set(.focused, to: true)
            return readable
        }
        var queue = [element]
        var visited: Set = [element]

        while !queue.isEmpty, visited.count <= limit {
            let current = queue.removeFirst()
            if let readable = try? current.readableElement() {
                Log.accessibility.debug("found \(type(of: readable)) after visiting \(visited.count) element(s)")
                try? current.set(.focused, to: true)
                return readable
            }
            let role = try? current.role()
            Log.accessibility.debug("visiting \(role?.rawValue ?? "unknown role")")
            // Not every app supports navigation order (AppKit does).
            let children = (try? current.attribute(.childrenInNavigationOrder)) ?? (try? current.attribute(.children))
            for child in children ?? [] where !visited.contains(child) {
                visited.insert(child)
                queue.append(child)
            }
            guard role != .window, role != .application else { continue }
            if let parent = try? current.attribute(.parent), !visited.contains(parent) {
                visited.insert(parent)
                queue.append(parent)
            }
        }
        Log.accessibility.debug("no readable element after visiting \(visited.count) element(s)")
        return nil
    }

    private func readableAncestor(of element: AXElement) -> ReadableElement? {
        var current = element
        for _ in 0..<AXElement.maxDepth {
            guard let parent = try? current.attribute(.parent),
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
