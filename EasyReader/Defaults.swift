import Foundation
import AVKit
import Defaults
import KeyboardShortcuts

extension UserDefaults {
    // In-memory under tests: they run inside the Debug app. `UserDefaults` is thread-safe but not `Sendable`.
    nonisolated(unsafe) static let app: UserDefaults =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil ? .standard : InMemoryDefaults()
}

/// Never persists. Posts KVO on writes so `Defaults.updates`/`@Default` still observe changes.
private final class InMemoryDefaults: UserDefaults {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    override func object(forKey defaultName: String) -> Any? {
        lock.lock()
        defer { lock.unlock() }
        return values[defaultName]
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        willChangeValue(forKey: defaultName)
        lock.lock()
        values[defaultName] = value
        lock.unlock()
        didChangeValue(forKey: defaultName)
    }

    override func removeObject(forKey defaultName: String) { set(nil, forKey: defaultName) }

    override func dictionaryRepresentation() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

extension Defaults.Keys {
    static let nowPlayingCenterIntegration = Key<Bool>("NowPlayingCenterIntegration", default: true, suite: .app)

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
    static let readSelectedTextFallback = Key<Bool>("ReadSelectedTextFallback", default: false, suite: .app)

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

public struct AVSpeechSynthesisVoiceBridge: Defaults.Bridge, Sendable {
    public typealias Value = AVSpeechSynthesisVoice
    public typealias Serializable = String

    public func serialize(_ value: Value?) -> Serializable? {
        value?.identifier
    }

    public func deserialize(_ object: Serializable?) -> Value? {
        guard let object else { return nil }
        return AVSpeechSynthesisVoice(identifier: object)
    }
}

extension AVSpeechBoundary: Defaults.Serializable {
    public static let bridge = AVSpeechBoundaryBridge()
}

public struct AVSpeechBoundaryBridge: Defaults.Bridge, Sendable {
    public typealias Value = AVSpeechBoundary
    public typealias Serializable = Int

    public func serialize(_ value: Value?) -> Serializable? {
        value?.rawValue
    }

    public func deserialize(_ object: Serializable?) -> Value? {
        guard let object else { return nil }
        return AVSpeechBoundary(rawValue: object)
    }
}
