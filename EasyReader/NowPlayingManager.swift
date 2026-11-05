//
//  NowPlayingManager.swift
//  EasyReader
//
//  Created by Ewalk on 2025-01-18.
//

import Cocoa
import MediaPlayer
import Defaults

/// Media keys / Control Center (`MPRemoteCommandCenter`) and the Now Playing panel (`MPNowPlayingInfoCenter`)
/// for an `EasyReader`.
///
/// Remote commands are registered only while the integration is enabled and the reader is reading or paused,
/// so media keys go to other apps once reading stops.
@MainActor
final class NowPlayingManager {
    /// Remote commands this app supports. Any command not listed is never registered.
    enum Action: Equatable {
        case play
        case pause
        case stop
        case togglePlayPause
        case nextTrack
        case previousTrack
        /// Now Playing playback rate (the speed multiplier published in `nowPlayingInfo`).
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

    /// The "Now Playing Center" integration setting. Turning it off unregisters commands and clears the panel.
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

    /// Whether remote command targets are currently registered.
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

    /// Call on every reader state change.
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

    /// Now Playing playback rate → `speechRate`; the inverse of what `playbackInfo` publishes.
    static func setSpeechRate(fromPlaybackRate playbackRate: Float) {
        Defaults[.speechRate] = SpeechRate.clamped(SpeechRate.rate(forMultiplier: playbackRate))
    }

    // MARK: - Commands

    // TODO: keep commands registered (and the panel showing) after reading finishes on its own, so Play
    // afterwards does what Start does (read the frontmost text area). Unclear how that fits Now Playing
    // conventions: holding the media keys while idle steals them from other apps, and "finished" vs.
    // "stopped by the user" would need telling apart (EasyReader only reports `.stopped`).
    private func apply() {
        setCommandsRegistered(state != .stopped)
        switch state {
            case .reading:
                infoCenter.playbackState = .playing
                // FIXME: seems to get reset on every skip via Now Playing (maybe because it's "next track")
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

    /// Built outside the main actor: a closure formed in main-actor code gets a runtime isolation check,
    /// which would trap if MediaPlayer ever called it off the main thread. Hop to main explicitly instead.
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

    /// MediaPlayer may call the request handler off the main thread; a closure formed in main-actor code
    /// would trap on its isolation check there, so build it outside the main actor.
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
