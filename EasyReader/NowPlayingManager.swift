//
//  NowPlayingManager.swift
//  EasyReader
//
//  Created by Ewalk on 2025-01-18.
//

import Cocoa
import MediaPlayer
import Defaults

@objc protocol NowPlayingManagerDelegate {
    @objc optional func play(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus;
    @objc optional func stop(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus;
    @objc optional func pause(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus;
    @objc optional func togglePlayPause(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus;

    @objc optional func nextTrack(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus;
    @objc optional func previousTrack(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus;
    @objc optional func skipForward(_ event: MPSkipIntervalCommandEvent) -> MPRemoteCommandHandlerStatus;
    @objc optional func skipBackward(_ event: MPSkipIntervalCommandEvent) -> MPRemoteCommandHandlerStatus;
    @objc optional func seekForward(_ event: MPSeekCommandEvent) -> MPRemoteCommandHandlerStatus;
    @objc optional func seekBackward(_ event: MPSeekCommandEvent) -> MPRemoteCommandHandlerStatus;

    @objc optional func changePlaybackRate(_ event: MPChangePlaybackRateCommandEvent) -> MPRemoteCommandHandlerStatus;
    @objc optional func changePlaybackPosition(_ event: MPChangePlaybackPositionCommandEvent) -> MPRemoteCommandHandlerStatus;
}

final class NowPlayingManager: NSObject {
//    TODO: should these be property getters?
    private static let commandCenter = MPRemoteCommandCenter.shared()
    private static let infoCenter = MPNowPlayingInfoCenter.default()
    weak var delegate: NowPlayingManagerDelegate?

    @RemoteCommand(commandCenter.playCommand) var playCommand
    @RemoteCommand(commandCenter.stopCommand) var stopCommand
    @RemoteCommand(commandCenter.pauseCommand) var pauseCommand
    @RemoteCommand(commandCenter.togglePlayPauseCommand) var togglePlayPauseCommand

    @RemoteCommand(commandCenter.nextTrackCommand) var nextTrackCommand
    @RemoteCommand(commandCenter.previousTrackCommand) var previousTrackCommand
    @RemoteCommand(commandCenter.skipForwardCommand, MPSkipIntervalCommandEvent.self) var skipForwardCommand
    @RemoteCommand(commandCenter.skipBackwardCommand, MPSkipIntervalCommandEvent.self) var skipBackwardCommand
    @RemoteCommand(commandCenter.seekForwardCommand, MPSeekCommandEvent.self) var seekForwardCommand
    @RemoteCommand(commandCenter.seekBackwardCommand, MPSeekCommandEvent.self) var seekBackwardCommand

    @RemoteCommand(commandCenter.changePlaybackRateCommand, MPChangePlaybackRateCommandEvent.self) var changePlaybackRateCommand
    @RemoteCommand(commandCenter.changePlaybackPositionCommand, MPChangePlaybackPositionCommandEvent.self) var changePlaybackPositionCommand

//    TODO: cleanup these functions
//    TODO: add NSSound.beep()?
    func setupRemoteCommands() {
        playCommand = delegate?.play
        stopCommand = delegate?.stop
        pauseCommand = delegate?.pause
        togglePlayPauseCommand = delegate?.togglePlayPause

        nextTrackCommand = delegate?.nextTrack
        previousTrackCommand = delegate?.previousTrack
        skipForwardCommand = delegate?.skipForward
        skipBackwardCommand = delegate?.skipBackward
        seekForwardCommand = delegate?.seekForward
        seekBackwardCommand = delegate?.seekBackward

        changePlaybackRateCommand = delegate?.changePlaybackRate
        changePlaybackPositionCommand = delegate?.changePlaybackPosition

//        TODO: what other properties can be changed?
//        $skipForwardCommand.preferredIntervals = [1.0]
//        $skipBackwardCommand.preferredIntervals = [1.0]
//        $changePlaybackRateCommand.supportedPlaybackRates = [
//            NSNumber(value: AVSpeechUtteranceMinimumSpeechRate),
//            NSNumber(value: AVSpeechUtteranceDefaultSpeechRate),
//            NSNumber(value: AVSpeechUtteranceMaximumSpeechRate),
//        ]
    }

    func removeRemoteCommands() {
        if let delegate {
            self.delegate = nil
            setupRemoteCommands()
            self.delegate = delegate
        }
    }

//    FIXME: seems like this is getting set every time we skip via Now Playing Center? (may be because it's the "next track", so it automatically removes the info?)
    func updateInfo(_ readable: Readable?, state: EasyReader.State) {
        Log.nowPlaying.debug("update info: \(state)")
        switch state {
            case .reading:
                setupRemoteCommands()
                Self.infoCenter.playbackState = .playing
//                var info = Self.infoCenter.nowPlayingInfo ?? [String: Any]()
                if let readable {
                    var info = [String: Any]()
                    updateItemMetadata(&info, item: readable)
                    updatePlaybackInfo(&info)
                    Self.infoCenter.nowPlayingInfo = info
                }
            case .paused:
                Self.infoCenter.playbackState = .paused
            case .stopped:
                removeRemoteCommands()
                Self.infoCenter.playbackState = .stopped
                Self.infoCenter.nowPlayingInfo = nil
        }
    }

    private func updateItemMetadata(_ info: inout [String: Any], item readable: Readable) {
//        TODO: MPMediaItemProperty
//        info[MPMediaItemPropertyMediaType] = MPMediaType.anyAudio
//        info[MPMediaItemPropertyMediaType] = MPMediaType.anyAudio.rawValue
//        info[MPMediaItemPropertyMediaType] = NSNumber(value: MPMediaType.anyAudio.rawValue)
        info[MPMediaItemPropertyMediaType] = MPMediaType.anyAudio.rawValue
//        info[MPMediaItemPropertyMediaType] = MPMediaType.anyAudio.rawValue
//        info[MPMediaItemPropertyMediaType] = MPMediaType.audioBook.rawValue
//        info[MPMediaItemPropertyMediaType] = MPMediaType.podcast.rawValue
        info[MPMediaItemPropertyPlaybackDuration] = Double.infinity

        info[MPMediaItemPropertyTitle] = readable.title
        info[MPMediaItemPropertyAlbumTitle] = readable.groupTitle
        info[MPMediaItemPropertyArtist] = NSRunningApplication.current.localizedName
        info[MPMediaItemPropertyArtwork] = readable.icon.map({ artwork in
            MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
        })
    }

    private func updatePlaybackInfo(_ info: inout [String: Any]) {
//        TODO: MPNowPlayingInfoProperty
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = Defaults.Keys.speechRate.defaultValue * 2
        info[MPNowPlayingInfoPropertyPlaybackRate] = Defaults[.speechRate] * 2
//        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = Double.ulpOfOne
//        info[MPNowPlayingInfoPropertyPlaybackRate] = Double.ulpOfOne
    }
}

@propertyWrapper
struct RemoteCommand<Command: MPRemoteCommand, CommandEvent: MPRemoteCommandEvent> {
    private let command: Command
    private var handler: ((CommandEvent) -> MPRemoteCommandHandlerStatus)?
    private var target: Any?

    var projectedValue: Command { command }

    var wrappedValue: ((CommandEvent) -> MPRemoteCommandHandlerStatus)? {
        get { handler }
        set {
            handler = newValue
            if let target {
                command.removeTarget(target)
                self.target = nil
            }
            if let handler {
                target = command.addTarget() { event in
                    Log.nowPlaying.debug("command: \(type(of: event))")
                    return handler(event as! CommandEvent)
                }
            }
        }
    }

    init(_ command: Command, _ eventType: CommandEvent.Type = MPRemoteCommandEvent.self) {
        self.command = command
    }
}
