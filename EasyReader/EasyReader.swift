import AppKit
import AVFoundation
import Defaults

@MainActor
final class EasyReader: NSObject {
    private var stopType: StopType = .continue
    private var stopAfterUnit: StopType?
    private(set) var state: State = .stopped {
        didSet {
            guard state != oldValue else { return }
            Log.reader.debug("state \(oldValue) → \(state)")
            if state != .reading { stopAfterUnit = nil }
            if state == .reading { hasFinished = false }
            if state == .stopped {
                hasFinished = reachedEnd
                reachedEnd = false
                endRepeatingSkip()
                readable?.endReading()
            }
            delegate?.easyReader(self, didChangeState: state)
        }
    }

    private let synthesizer = AVSpeechSynthesizer()
    // Unlike `synthesizer.isSpeaking`, also covers the gap between `speak` and `didStart`.
    private(set) var currentUtterance: AVSpeechUtterance?
    private var hasCurrentUtteranceStarted = false
    private var isSpeaking: Bool { synthesizer.isSpeaking || currentUtterance != nil }
    var textSelector: TextSelector? {
        didSet { forwardCache = nil }
    }
    var readable: Readable? {
        didSet {
            guard readable !== oldValue else { return }
            textLength = nil
            forwardCache = nil
            hasFinished = false
            // Stopping already ended it, unless its first utterance hasn't started yet
            if state != .stopped || currentUtterance != nil { oldValue?.endReading() }
            oldValue?.onInvalidate = nil
            readable?.onInvalidate = { [weak self] in
                Log.reader.debug("readable invalidated, stopping")
                self?.stop(immediately: true)
                self?.readable = nil
            }
        }
    }
    weak var delegate: Delegate?
    private var lastSelection: Selection?
    // Before pronunciations are applied.
    private var readText: String?
    private var utteranceOffset = 0
    private(set) var spokenText: SpokenText?
    private var lastReadOffset: Int?
    private var pendingStart: Task<Void, Never>?
    private var repeatingSkip: Task<Void, Never>?
    /// Stopped because the text ran out, not by the user.
    private(set) var hasFinished = false {
        didSet {
            guard !hasFinished, oldValue, state == .stopped else { return }
            delegate?.easyReader(self, didChangeState: state)
        }
    }
    private var reachedEnd = false
    // Fetching `fullText` per utterance is slow on web pages
    private var textLength: Int?
    // `canSkipForward` runs on every menu/toolbar validation
    private var forwardCache: (readable: ObjectIdentifier, selection: Selection, text: String, next: Selection)?
    private var pronunciationCache: (stored: NSObject?, rules: [Pronunciation.Compiled])?

    /// Speech position in `fullText` (UTF-16).
    struct Progress: Equatable {
        let position: Int
        let length: Int
    }

    var progress: Progress? {
        guard let textLength, let start = lastSelection?.lowerBound else { return nil }
        return Progress(position: min(start + (lastReadOffset ?? utteranceOffset), textLength), length: textLength)
    }

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    @discardableResult
    func play(from unit: ResumeUnit) -> Bool {
        // A speech-setting restart: Books would copy the selection again
        if state != .reading { readable?.beginReading() }
        let started = resume(from: unit)
        if !started, state == .stopped { readable?.endReading() }
        return started
    }

    private func resume(from unit: ResumeUnit) -> Bool {
        let current = readable?.selection
        guard let selection = current, lastSelection == selection else {
            Log.reader.debug(
                "play(from: \(unit)): selection changed (\(String(describing: lastSelection)) → \(String(describing: current))), reading selection")
            return ensureSelection(current) && readSelection()
        }
        Log.reader.debug("play(from: \(unit)): resuming \(selection), last spoken offset \(String(describing: lastReadOffset))")
        scroll(to: selection)
        switch unit {
            case .word: return readSelection(from: lastReadOffset)
            case .selection: return readSelection()
        }
    }

    /// Reads the finished text again from the top, whatever was selected in it since.
    func rereadFinished() -> Bool {
        guard hasFinished, let readable, let length = readable.fullText?.utf16.count else { return false }
        // At the end, as finishing leaves it: playing wraps around to the start.
        readable.selection = Selection(length..<length)
        return play(from: .selection)
    }

    func prepareForTermination() {
        readable?.endReading()
    }

    @discardableResult
    func pause() -> Bool {
        endRepeatingSkip()
        guard isSpeaking else {
            Log.reader.debug("pause: not speaking")
            return false
        }
        Log.reader.debug("pause (stopType was \(stopType))")
        return stopSpeaking(.pause)
    }

    /// `immediately`: ignores the stop boundary (the text went away).
    @discardableResult
    func stop(immediately: Bool = false) -> Bool {
        endRepeatingSkip()
        pendingStart?.cancel()
        pendingStart = nil
        guard isSpeaking else {
            guard state == .paused else {
                if hasFinished {
                    Log.reader.debug("stop: after finishing")
                    hasFinished = false
                    return true
                }
                Log.reader.debug("stop: not speaking or paused")
                return false
            }
            Log.reader.debug("stop: while paused")
            state = .stopped
            return true
        }
        Log.reader.debug("stop (stopType was \(stopType))")
        return stopSpeaking(.cancel, immediately: immediately)
    }

    /// `.selection`: a second request doesn't wait for the unit's end.
    private func stopSpeaking(_ type: StopType, immediately: Bool = false) -> Bool {
        let boundary = immediately ? .immediate : Defaults[.speechStopBoundary]
        if boundary == .selection, stopAfterUnit == nil {
            Log.reader.debug("\(type) after this unit")
            stopAfterUnit = type
            return true
        }
        stopAfterUnit = nil
        stopType = type
        let stopped = synthesizer.stopSpeaking(at: boundary == .immediate ? .immediate : .word)
        // Not started yet: it may get no callback at all (queued behind an interrupted one), so stop it here
        guard currentUtterance == nil || hasCurrentUtteranceStarted else {
            currentUtterance = nil
            applyStopType()
            return true
        }
        return stopped
    }

    @discardableResult
    func togglePlayPause() -> Bool {
        switch state {
            case .reading: return pause()
            case .paused: return play(from: Defaults[.resumeUnit])
            case .stopped: return play(from: .selection)
        }
    }

    /// Forward on the last unit (of the main content too) does nothing; reaching the end on its own still stops (`advance`).
    /// Backward on the first unit restarts it, unless `restartingAtStart` is false.
    @discardableResult
    func skip(_ direction: Selection.Direction, restartingAtStart: Bool = true) -> Bool {
        if direction == .forward, !canSkipForward {
            Log.reader.debug("skip(forward): at last unit, ignoring")
            return false
        }
        return advance(direction, restartingAtStart: restartingAtStart)
    }

    static let repeatingSkipIntervals: ClosedRange<Double> = 0.05...1
    static var repeatingSkipInterval: TimeInterval {
        Defaults[.repeatingSkipInterval].clamped(to: repeatingSkipIntervals)
    }

    /// Held skip key: skips now, then again after `delay` and every `repeatingSkipInterval` until `endRepeatingSkip()`, pause/stop, or a skip fails.
    @discardableResult
    func beginRepeatingSkip(_ direction: Selection.Direction, firstRepeatAfter delay: TimeInterval? = nil) -> Bool {
        endRepeatingSkip()
        guard skip(direction) else { return false }
        repeatingSkip = Task { [weak self] in
            var wait = delay ?? Self.repeatingSkipInterval
            while true {
                try? await Task.sleep(seconds: wait)
                guard !Task.isCancelled, let self, skip(direction, restartingAtStart: false) else { return }
                wait = Self.repeatingSkipInterval
            }
        }
        return true
    }

    func endRepeatingSkip() {
        repeatingSkip?.cancel()
        repeatingSkip = nil
    }

    var canSkipForward: Bool {
        nextSelection(.forward).map { !$0.isEmpty } ?? false
    }

    @discardableResult
    private func advance(
        _ direction: Selection.Direction, from selection: Selection? = nil, pausingFirst: Bool = false, restartingAtStart: Bool = true
    ) -> Bool {
        guard select(direction, from: selection) else {
            if direction == .backward {
                guard restartingAtStart else { return false }
                Log.reader.debug("skip(backward): at start, re-reading current selection")
                return ensureSelection(readable?.selection) && readSelection()
            }
            Log.reader.debug("skip(\(direction)): nothing to select, stopping")
            reachedEnd = direction == .forward
            return stop()
        }
        return readSelection(pausingFirst: pausingFirst)
    }

    func pronunciations(with appDomain: String?) -> [Pronunciation] {
        compiledPronunciations(with: appDomain).map(\.rule)
    }

    /// Decoded and compiled again only when the stored rules change.
    private func compiledPronunciations(with appDomain: String?) -> [Pronunciation.Compiled] {
        let stored = UserDefaults.app.object(forKey: Defaults.Keys.pronunciations.name) as? NSObject
        if pronunciationCache == nil || pronunciationCache?.stored != stored {
            pronunciationCache = (stored, Defaults[.pronunciations].filter(\.enabled).map(Pronunciation.Compiled.init))
        }
        return pronunciationCache?.rules.filter { $0.rule.appDomain == nil || $0.rule.appDomain == appDomain } ?? []
    }

    private func read(_ spoken: SpokenText, pausingFirst: Bool) {
        let utterance = AVSpeechUtterance(spoken)
        // Pause after selecting the next unit, so a stop after the unit doesn't wait for it
        if pausingFirst { utterance.preUtteranceDelay = Defaults[.pauseBetweenUnits] }
        Log.speech.debug(
            "speak \(spoken.text.utf16.count) chars (voice \(utterance.voice?.identifier ?? "default"), rate \(utterance.rate)): \(spoken.text.prefix(80).debugDescription)"
        )
        lastSelection = readable?.selection
        spokenText = spoken
        lastReadOffset = nil
        stopType = .continue
        currentUtterance = utterance
        hasCurrentUtteranceStarted = false
        synthesizer.speak(utterance)
    }

    private func scroll(to selection: Selection) {
        guard Defaults[.scrollSelectionIntoView] else { return }
        readable?.scroll(
            to: selection,
            options: ScrollOptions(padding: Defaults[.scrollPadding], duration: Defaults[.scrollDuration]))
    }

    /// From `selection`, else the readable's.
    private func nextSelection(_ direction: Selection.Direction, from selection: Selection? = nil) -> Selection? {
        guard let readable,
            let fullText = readable.fullText,
            let selection = selection ?? readable.selection,
            let textSelector
        else {
            Log.reader.debug("nextSelection(\(direction)): no text, selection, or selector")
            return nil
        }
        let length = fullText.utf16.count
        textLength = length
        let id = ObjectIdentifier(readable)
        if direction == .forward, let cache = forwardCache, cache.readable == id, cache.selection == selection, cache.text == fullText {
            return cache.next
        }
        var nextSelection = textSelector.select(direction, from: selection, in: fullText, blocks: { readable.textBlock(containing: $0) })
        // Reading the main content ends with it (a user selection past it reads on to the text's end)
        if direction == .forward, let end = readable.contentEnd, selection.lowerBound < end, nextSelection.lowerBound >= end {
            Log.reader.debug("nextSelection(forward): past the main content's end at \(end)")
            nextSelection = Selection(length..<length)
        }
        if direction == .forward { forwardCache = (id, selection, fullText, nextSelection) }
        Log.reader.debug("nextSelection(\(direction)): \(selection) → \(nextSelection) of \(length)")
        return nextSelection
    }

    private func select(_ direction: Selection.Direction, from selection: Selection? = nil) -> Bool {
        guard let nextSelection = nextSelection(direction, from: selection) else { return false }
        // Forward keeps the empty end selection: `ensureSelection` wraps around from it.
        guard direction == .forward || !nextSelection.isEmpty else { return false }
        readable?.selection = nextSelection
        scroll(to: nextSelection)
        return !nextSelection.isEmpty
    }

    private func ensureSelection(_ selection: Selection?) -> Bool {
        guard let fullText = readable?.fullText, let selection else {
            Log.reader.debug("ensureSelection: no text or selection")
            return false
        }
        textLength = fullText.utf16.count
        guard selection.startIndex(in: fullText) != fullText.endIndex else {
            let start = min(readable?.contentStart ?? 0, fullText.utf16.count)
            Log.reader.debug("ensureSelection: selection at end of text, wrapping to \(start)")
            readable?.selection = Selection(start..<start)
            return select(.forward, from: Selection(start..<start))
        }
        guard !selection.isEmpty else {
            Log.reader.debug("ensureSelection: empty selection at \(selection.lowerBound), selecting next unit")
            return select(.forward, from: selection)
        }
        scroll(to: selection)
        return true
    }

    /// From `offset` (in the original selected text) only if it's still the text last read.
    private func readSelection(from offset: Int? = nil, pausingFirst: Bool = false) -> Bool {
        guard let selectedText = readable?.selectedText else {
            Log.reader.debug("readSelection: no selected text")
            return false
        }
        let pronunciations = compiledPronunciations(with: readable?.appDomain)
        if !pronunciations.isEmpty {
            Log.reader.debug("applying \(pronunciations.count) pronunciation(s) for \(readable?.appDomain ?? "any app")")
        }
        var start = 0
        var text = selectedText
        if let offset, selectedText == readText {
            let index = Selection(offset..<offset).startIndex(in: selectedText)
            start = selectedText.utf16.distance(from: selectedText.utf16.startIndex, to: index)
            text = String(selectedText[index...])
            Log.reader.debug("resuming from offset \(offset)")
        }
        readText = selectedText
        utteranceOffset = start
        let spoken = SpokenText(text, compiled: pronunciations)
        if isSpeaking {
            Log.reader.debug("interrupting current utterance (stopType was \(stopType))")
            synthesizer.stopSpeaking(at: .immediate)
        }
        read(spoken, pausingFirst: pausingFirst)
        return true
    }
}

// Called on main; `@preconcurrency` checks that at runtime.
extension EasyReader: @preconcurrency AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Log.speech.debug("didStart")
        guard utterance === currentUtterance else {
            Log.speech.debug("ignoring didStart of an interrupted utterance")
            return
        }
        hasCurrentUtteranceStarted = true
        state = .reading
        delegate?.easyReaderDidStartUtterance(self)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Log.speech.debug("didFinish (stopType \(stopType))")
        guard endCurrent(utterance) else { return }
        if stopType == .continue, let pending = stopAfterUnit {
            finishUnit(then: pending)
            applyStopType()
            return
        }
        // macOS reports `didFinish` for `stopSpeaking` too, hence the `stopType` check.
        guard stopType == .continue,
            let selection = readable?.selection,
            !selection.isEmpty,
            advance(.forward, from: selection, pausingFirst: true)
        else {
            if stopType == .continue { stopType = .cancel }
            applyStopType()
            return
        }
    }

    /// Callbacks of an utterance interrupted by a newer one are stale: `stopType` belongs to the newer one.
    private func endCurrent(_ utterance: AVSpeechUtterance) -> Bool {
        guard utterance === currentUtterance else {
            Log.speech.debug("ignoring callback of an interrupted utterance")
            return false
        }
        currentUtterance = nil
        return true
    }

    private func finishUnit(then pending: StopType) {
        stopAfterUnit = nil
        if select(.forward) {
            Log.reader.debug("unit finished, \(pending) before next unit")
            lastSelection = readable?.selection
            lastReadOffset = nil
            utteranceOffset = 0
            stopType = pending
        } else {
            Log.reader.debug("unit finished at end of text, stopping")
            reachedEnd = true
            stopType = .cancel
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Log.speech.debug("didCancel (stopType \(stopType))")
        guard endCurrent(utterance) else { return }
        applyStopType()
    }

    private func applyStopType() {
        switch stopType {
            case .continue: break
            case .pause: state = .paused
            case .cancel:
                // Stopped before it started speaking: no state change ends reading
                if state == .stopped { readable?.endReading() }
                state = .stopped
        }
        reachedEnd = false
        stopType = .continue
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
    @MainActor
    protocol Delegate: AnyObject {
        func easyReader(_ reader: EasyReader, didChangeState state: State)
        func easyReaderDidStartUtterance(_ reader: EasyReader)
    }

    enum StopType {
        case `continue`
        case pause
        case cancel
    }

    enum State {
        case reading
        case paused
        case stopped
    }

    enum StopBoundary: String, Defaults.Serializable {
        case immediate
        case word
        case selection
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
        pendingStart?.cancel()
        pendingStart = nil
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
        if getpid() != (try? element.pid()) {
            guard AXElement.isProcessTrusted(prompt: true) else {
                Log.accessibility.error("No accessibility API permission.")
                return false
            }
        }
        let focusedElement = Self.startElement(element, fromFocused: fromFocused)
        guard let focusedElement, let readableElement = findReadableElement(from: focusedElement) else {
            if focusedElement != nil, let pid = try? element.pid(), pid != getpid() {
                let isChromium = NSRunningApplication(processIdentifier: pid).map(AppAccessibility.isChromium) ?? false
                let flags = AppAccessibility.enable(pid: pid)
                if !flags.isEmpty {
                    return startAfterEnabling(flags, reading: element, fromFocused: fromFocused, pid: pid, tries: isChromium ? 50 : 15)
                }
            }
            return readSelectionInReaderWindow(of: element, failure: focusedElement == nil ? "Unable to get focused element." : nil)
        }
        return start(reading: readableElement)
    }

    private static func startElement(_ element: AXElement, fromFocused: Bool) -> AXElement? {
        fromFocused ? try? element.attribute(.focusedUIElement) : element
    }

    // Some apps (like Chromium) vend no content until their AX mode is on; retry (every 0.1 s) while they build the tree.
    private func startAfterEnabling(
        _ flags: [AXAttribute<Bool>], reading element: AXElement, fromFocused: Bool, pid: pid_t, tries: Int
    ) -> Bool {
        Log.accessibility.debug("turned on \(flags); waiting for content")
        pendingStart?.cancel()
        pendingStart = Task { [weak self] in
            for _ in 0..<tries {
                guard (try? await Task.sleep(seconds: 0.1)) != nil, let self else { break }
                guard let focused = Self.startElement(element, fromFocused: fromFocused), let readable = findReadableElement(from: focused) else { continue }
                if let webArea = readable as? WebAreaReadableElement {
                    webArea.adoptAppFlags(flags)
                } else {
                    AppAccessibility.restore(flags, pid: pid)
                }
                pendingStart = nil
                NSSound.beep(unless: start(reading: readable))
                return
            }
            AppAccessibility.restore(flags, pid: pid)
            if !Task.isCancelled {
                NSSound.beep(unless: self?.readSelectionInReaderWindow(of: element) == true)
            }
        }
        return true
    }

    /// For apps with nothing readable (`readSelectedTextFallback`); logs `failure` when it's off or fails.
    private func readSelectionInReaderWindow(of element: AXElement, failure: String? = nil) -> Bool {
        if Defaults[.readSelectedTextFallback], let pid = try? element.pid(), ReaderWindow.readSelection(of: pid) { return true }
        Log.accessibility.error(failure ?? "Unable to find readable element.")
        return false
    }

    /// BFS over children and parents, never climbing past the window.
    private func findReadableElement(from element: AXElement, limit: Int = 1000) -> ReadableElement? {
        let startReadable = try? element.readableElement()
        // Focus is often deep inside one (a link in a web page): climb before the BFS fans out over the page.
        if startReadable == nil, let (ancestor, readable) = readableAncestor(of: element) {
            try? ancestor.set(.focused, to: true)
            return readable
        }
        var queue = [element]
        var visited: Set = [element]

        while !queue.isEmpty, visited.count <= limit {
            let current = queue.removeFirst()
            if let readable = current == element ? startReadable : (try? current.readableElement()) {
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

    private func readableAncestor(of element: AXElement) -> (AXElement, ReadableElement)? {
        var current = element
        for _ in 0..<AXElement.maxDepth {
            guard let parent = try? current.attribute(.parent),
                let role = try? parent.role(), role != .window, role != .application
            else { return nil }
            if let readable = try? parent.readableElement() {
                Log.accessibility.debug("found \(type(of: readable)) as an ancestor of the focused element")
                return (parent, readable)
            }
            current = parent
        }
        return nil
    }
}

extension AVSpeechUtterance {
    convenience init(_ spoken: SpokenText) {
        if spoken.hasPhonetics { self.init(attributedString: spoken.attributedText) } else { self.init(string: spoken.text) }
        voice = Defaults[.speechVoice] ?? .system
        volume = Defaults[.speechVolume]
        rate = Defaults[.speechRate]
        pitchMultiplier = Defaults[.speechPitch]
    }
}
