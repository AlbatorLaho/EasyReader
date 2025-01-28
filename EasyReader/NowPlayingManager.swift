//
//  NowPlayingManager.swift
//  EasyReader
//
//  Created by Ewalk on 2025-01-18.
//

import Cocoa
import MediaPlayer

@objc protocol NowPlayingManagerDelegate {
    @objc optional func play(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus;
    @objc optional func stop(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus;
    @objc optional func pause(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus;
    @objc optional func togglePlayPause(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus;

    @objc optional func nextTrack(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus;
    @objc optional func previousTrack(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus;
    @objc optional func skipForward(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus;
    @objc optional func skipBackward(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus;
    @objc optional func seekForward(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus;
    @objc optional func seekBackward(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus;

    @objc optional func changePlaybackRate(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus;
    @objc optional func changePlaybackPosition(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus;
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
    @RemoteCommand(commandCenter.skipForwardCommand) var skipForwardCommand
    @RemoteCommand(commandCenter.skipBackwardCommand) var skipBackwardCommand
    @RemoteCommand(commandCenter.seekForwardCommand) var seekForwardCommand
    @RemoteCommand(commandCenter.seekBackwardCommand) var seekBackwardCommand

    @RemoteCommand(commandCenter.changePlaybackRateCommand) var changePlaybackRateCommand
    @RemoteCommand(commandCenter.changePlaybackPositionCommand) var changePlaybackPositionCommand

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
//        Self.commandCenter.changePlaybackRateCommand.supportedPlaybackRates
//        Self.commandCenter.skipForwardCommand.preferredIntervals
    }

    func removeRemoteCommands() {
        if let delegate {
            self.delegate = nil
            setupRemoteCommands()
            self.delegate = delegate
        }
    }

    func updateInfo(_ readable: Readable?, state: EasyReader.State) {
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
            case .stopped:
                removeRemoteCommands()
                Self.infoCenter.playbackState = .stopped
                Self.infoCenter.nowPlayingInfo = nil
            case .paused:
                Self.infoCenter.playbackState = .paused
            default:
                Self.infoCenter.playbackState = .unknown
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
        info[MPMediaItemPropertyTitle] = readable.title
        info[MPMediaItemPropertyAlbumTitle] = readable.groupTitle
        info[MPMediaItemPropertyArtist] = NSRunningApplication.current.localizedName
        info[MPMediaItemPropertyArtwork] = readable.icon.map { artwork in
            MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
        }
    }

    private func updatePlaybackInfo(_ info: inout [String: Any]) {
//        TODO: MPNowPlayingInfoProperty
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 0.5
        info[MPNowPlayingInfoPropertyPlaybackRate] = 0.5
//        info[MPNowPlayingInfoPropertyPlaybackRate] = easyReader.rate
    }
}

@propertyWrapper
struct RemoteCommand {
    private let command: MPRemoteCommand
    private var handler: ((MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus)?
    private var target: Any?

    var projectedValue: MPRemoteCommand { command }

    var wrappedValue: ((MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus)? {
        get { handler }
        set {
            handler = newValue
            if let target {
                command.removeTarget(target)
                self.target = nil
            }
            if let handler {
                target = command.addTarget(handler: handler)
            }
        }
    }

    init(_ command: MPRemoteCommand) {
        self.command = command
    }
}
