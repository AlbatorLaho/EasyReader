import Cocoa
import MediaPlayer
import Defaults

/// Media keys and the Now Playing panel. Commands are registered only while enabled and not stopped,
/// so media keys go to other apps once reading stops.
@MainActor
final class NowPlayingManager {
    enum Action: Equatable {
        case play
        case pause
        case stop
        case togglePlayPause
        case nextTrack
        case previousTrack
        /// Speed multiplier.
        case changePlaybackRate(Float)
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
            Registration(command: center.changePlaybackRateCommand) { event in
                (event as? MPChangePlaybackRateCommandEvent).map { .changePlaybackRate($0.playbackRate) }
            },
        ]
    }

    func update(readable: Readable?, state: EasyReader.State) {
        self.readable = readable
        self.state = state
        guard isEnabled else { return }
        apply()
    }

    @discardableResult
    func perform(_ action: Action) -> MPRemoteCommandHandlerStatus {
        Log.nowPlaying.debug("command: \(String(describing: action))")
        let succeeded: Bool
        switch action {
            case .play: succeeded = reader.play(from: .selection)
            case .pause: succeeded = reader.pause()
            case .stop: succeeded = reader.stop()
            case .togglePlayPause: succeeded = reader.togglePlayPause()
            case .nextTrack: succeeded = reader.skip(.forward)
            case .previousTrack: succeeded = reader.skip(.backward)
            case .changePlaybackRate(let playbackRate):
                Self.setSpeechRate(fromPlaybackRate: playbackRate)
                succeeded = true
        }
        return succeeded ? .success : .commandFailed
    }

    static func setSpeechRate(fromPlaybackRate playbackRate: Float) {
        Defaults[.speechRate] = SpeechRate.clamped(SpeechRate.rate(forMultiplier: playbackRate))
    }

    // MARK: - Commands

    private func apply() {
        setCommandsRegistered(state != .stopped)
        switch state {
            case .reading:
                infoCenter.playbackState = .playing
                if let readable {
                    infoCenter.nowPlayingInfo = Self.itemMetadata(readable).merging(Self.playbackInfo()) { $1 }
                }
            case .paused:
                infoCenter.playbackState = .paused
            case .stopped:
                clearInfo()
        }
    }

    private func setCommandsRegistered(_ registered: Bool) {
        guard registered != areCommandsRegistered else { return }
        areCommandsRegistered = registered
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

    private static func itemMetadata(_ readable: Readable) -> [String: Any] {
        var info: [String: Any] = [
            MPMediaItemPropertyMediaType: MPMediaType.anyAudio.rawValue,
            MPMediaItemPropertyPlaybackDuration: Double.infinity,
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

    private static func playbackInfo() -> [String: Any] {
        [
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: SpeechRate.multiplier(forRate: Defaults.Keys.speechRate.defaultValue),
            MPNowPlayingInfoPropertyPlaybackRate: SpeechRate.multiplier(forRate: Defaults[.speechRate]),
        ]
    }
}
