import Cocoa
import MediaPlayer
import Defaults

/// Media keys and the Now Playing panel: commands registered only while enabled and not stopped (or held after finishing).
@MainActor
final class NowPlayingManager {
    enum Action: Equatable {
        case play
        case pause
        case stop
        case togglePlayPause
        case nextTrack
        case previousTrack
        /// Holding ⏮/⏭: `EasyReader.beginRepeatingSkip` until released.
        case seek(Selection.Direction, begin: Bool)
        /// Speed multiplier.
        case changePlaybackRate(Float)
    }

    enum PlayWhenFinished: String, Defaults.Serializable {
        /// Media keys go back to other apps.
        case off
        /// The finished text again, from the start.
        case sameText
        /// Like Start, but only while the finished text's app is in front.
        case sameApp
        /// Like Start.
        case anyText
    }

    private struct Registration {
        let command: MPRemoteCommand
        let action: (MPRemoteCommandEvent) -> Action?
        var target: Any?
    }

    private let reader: EasyReader
    private let infoCenter = MPNowPlayingInfoCenter.default()
    private var registrations: [Registration]
    private var readable: Readable?
    private var state: EasyReader.State = .stopped
    private var progress: EasyReader.Progress?
    private var hasFinished = false
    // Title and artwork, per readable: the title is an AX call.
    private var metadata: (readable: Readable, info: [String: Any])?

    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            Log.nowPlaying.debug("integration \(isEnabled ? "enabled" : "disabled")")
            if isEnabled {
                apply()
            } else {
                setCommandsRegistered(false)
                clearInfo()
            }
        }
    }

    private(set) var areCommandsRegistered = false

    init(reader: EasyReader) {
        self.reader = reader
        let center = MPRemoteCommandCenter.shared()
        registrations = [
            Registration(command: center.playCommand) { _ in .play },
            Registration(command: center.pauseCommand) { _ in .pause },
            Registration(command: center.stopCommand) { _ in .stop },
            Registration(command: center.togglePlayPauseCommand) { _ in .togglePlayPause },
            Registration(command: center.nextTrackCommand) { _ in .nextTrack },
            Registration(command: center.previousTrackCommand) { _ in .previousTrack },
            Registration(command: center.seekForwardCommand) { event in
                (event as? MPSeekCommandEvent).map { .seek(.forward, begin: $0.type == .beginSeeking) }
            },
            Registration(command: center.seekBackwardCommand) { event in
                (event as? MPSeekCommandEvent).map { .seek(.backward, begin: $0.type == .beginSeeking) }
            },
            Registration(command: center.changePlaybackRateCommand) { event in
                (event as? MPChangePlaybackRateCommandEvent).map { .changePlaybackRate($0.playbackRate) }
            },
        ]
    }

    func update(readable: Readable?, state: EasyReader.State, progress: EasyReader.Progress? = nil, hasFinished: Bool = false) {
        self.readable = readable
        self.state = state
        self.progress = progress
        self.hasFinished = hasFinished
        guard isEnabled else { return }
        apply()
    }

    @discardableResult
    func perform(_ action: Action) -> MPRemoteCommandHandlerStatus {
        Log.nowPlaying.debug("command: \(String(describing: action))")
        if reader.hasFinished, Defaults[.playWhenFinished] != .off, action == .play || action == .togglePlayPause {
            return playAfterFinishing() ? .success : .commandFailed
        }
        let succeeded: Bool
        switch action {
            case .play: succeeded = reader.state == .reading || reader.togglePlayPause()
            case .pause: succeeded = reader.pause()
            case .stop: succeeded = reader.stop()
            case .togglePlayPause: succeeded = reader.togglePlayPause()
            case .nextTrack: succeeded = reader.skip(.forward)
            case .previousTrack: succeeded = reader.skip(.backward)
            case .seek(let direction, begin: true):
                // Seeking begins ~0.4 s after the key goes down: the first repeat comes one interval later.
                succeeded = reader.beginRepeatingSkip(direction)
            case .seek(_, begin: false):
                reader.endRepeatingSkip()
                succeeded = true
            case .changePlaybackRate(let playbackRate):
                Self.setSpeechRate(fromPlaybackRate: playbackRate)
                succeeded = true
        }
        return succeeded ? .success : .commandFailed
    }

    private func playAfterFinishing() -> Bool {
        switch Defaults[.playWhenFinished] {
            case .off, .sameText:  // .off: not reached
                return reader.rereadFinished()
            case .sameApp:
                guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == readable?.appDomain else {
                    Log.nowPlaying.debug("play when finished: finished text's app isn't in front")
                    NSSound.beep()
                    return false
                }
                return reader.start(reading: .app(app))
            case .anyText:
                return reader.start(reading: .frontmostApp)
        }
    }

    static func setSpeechRate(fromPlaybackRate playbackRate: Float) {
        Defaults[.speechRate] = SpeechRate.clamped(SpeechRate.rate(forMultiplier: playbackRate))
    }

    // MARK: - Commands

    private var isHoldingAfterFinishing: Bool {
        state == .stopped && hasFinished && readable != nil && Defaults[.playWhenFinished] != .off
    }

    private func apply() {
        setCommandsRegistered(state != .stopped || isHoldingAfterFinishing)
        switch state {
            case .reading:
                infoCenter.playbackState = .playing
                publishInfo(rate: SpeechRate.multiplier(forRate: Defaults[.speechRate]))
            case .paused:
                infoCenter.playbackState = .paused
                publishInfo(rate: 0)
            case .stopped:
                guard isHoldingAfterFinishing else {
                    clearInfo()
                    return
                }
                infoCenter.playbackState = .paused
                progress = progress.map { EasyReader.Progress(position: $0.length, length: $0.length) }
                publishInfo(rate: 0)
        }
    }

    private func setCommandsRegistered(_ registered: Bool) {
        guard registered != areCommandsRegistered else { return }
        areCommandsRegistered = registered
        if !registered { reader.endRepeatingSkip() }
        Log.nowPlaying.debug("\(registered ? "registering" : "removing") remote commands")
        for index in registrations.indices {
            if registered {
                let action = registrations[index].action
                registrations[index].target = Self.addTarget(to: registrations[index].command) { [weak self] event in
                    guard let self, let action = action(event) else { return .commandFailed }
                    return perform(action)
                }
            } else if let target = registrations[index].target {
                registrations[index].command.removeTarget(target)
                registrations[index].target = nil
            }
        }
    }

    // Nonisolated: a closure formed on the main actor would trap if MediaPlayer called it off main.
    private nonisolated static func addTarget(
        to command: MPRemoteCommand,
        handler: @escaping @MainActor (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus
    ) -> Any {
        command.addTarget { event in
            nonisolated(unsafe) let event = event
            if Thread.isMainThread {
                return MainActor.assumeIsolated { handler(event) }
            }
            // Would deadlock if main ever waited on MediaPlayer's callback thread.
            return DispatchQueue.main.sync { MainActor.assumeIsolated { handler(event) } }
        }
    }

    // MARK: - Info

    private func clearInfo() {
        infoCenter.playbackState = .stopped
        infoCenter.nowPlayingInfo = nil
    }

    private func publishInfo(rate: Float) {
        guard let readable else { return }
        if metadata?.readable !== readable { metadata = (readable, Self.itemMetadata(readable)) }
        infoCenter.nowPlayingInfo = (metadata?.info ?? [:]).merging(Self.playbackInfo(progress: progress, rate: rate)) { $1 }
    }

    private static func itemMetadata(_ readable: Readable) -> [String: Any] {
        var info: [String: Any] = [
            MPMediaItemPropertyMediaType: MPMediaType.anyAudio.rawValue
        ]
        info[MPMediaItemPropertyTitle] = readable.title
        info[MPMediaItemPropertyAlbumTitle] = readable.groupTitle
        info[MPMediaItemPropertyArtist] = NSRunningApplication.current.localizedName
        info[MPMediaItemPropertyArtwork] = readable.icon.map(artwork)
        return info
    }

    // Nonisolated: MediaPlayer may call the handler off main.
    private nonisolated static func artwork(_ image: NSImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    // Measured with the default voice at 1×.
    static let charactersPerSecond = 17.0

    // Times at 1×: the panel advances them by `rate`.
    private static func playbackInfo(progress: EasyReader.Progress?, rate: Float) -> [String: Any] {
        var info: [String: Any] = [
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: SpeechRate.multiplier(forRate: Defaults.Keys.speechRate.defaultValue),
            MPNowPlayingInfoPropertyPlaybackRate: rate,
        ]
        if let progress {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(progress.position) / charactersPerSecond
            info[MPMediaItemPropertyPlaybackDuration] = Double(progress.length) / charactersPerSecond
        }
        return info
    }
}
