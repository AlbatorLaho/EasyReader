//
//  EasyReaderApp.swift
//  EasyReader
//
//  Created by Ewalk on 24/11/2.
//

import SwiftUI
import MediaPlayer
import AXSwift
import Defaults

@main
struct EasyReaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
//    @Environment(\.openSettings) private var openSettings
//    @Environment(\.openWindow) private var openWindow

//    init() {
//        NSApplication.shared.setActivationPolicy(.accessory)
//        NSApplication.shared.setActivationPolicy(.prohibited)
//    }

    var body: some Scene {
#if DEBUG
        WindowGroup {
            ContentView(appDelegate: appDelegate)
        }
#endif
        Settings {
//            EmptyView()
            SettingsView()
                .onAppear() {
                    NSApplication.shared.setActivationPolicy(.regular)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
                .onExitCommand() {
                    print("exit")
                }
                .onDisappear() {
                    print("disappear")
                    NSApplication.shared.setActivationPolicy(.prohibited)
                }
//                .textFieldStyle(.roundedBorder)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var easyReader: EasyReader!
    var statusItem: NSStatusItem!
//    TODO: handle these better
    var readerStateImageDefault = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)!
    var readerStateImages: [EasyReader.State: String] = [
//        .stopped: "waveform",
        .stopped: "waveform.slash",
//        .paused: "waveform",
//        .reading: "waveform",
        .error: "waveform.badge.exclamationmark",
    ]
    
//    TODO: use .prohibited unless a window needs to be opened, then use .accessory or .regular (make sure the permisions dialog can be opened)
    func applicationWillFinishLaunching(_ notification: Notification) {
#if !DEBUG
        NSApplication.shared.setActivationPolicy(.prohibited)
//        NSApplication.shared.setActivationPolicy(.accessory)
#endif
//        NSApplication.shared.setActivationPolicy(.regular)
//        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        easyReader = EasyReader()
        easyReader.textSelector = NLTextSelector(unit: .sentence)
        easyReader.delegate = self
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = readerStateImageDefault
        statusItem.menu = NSMenu()
        statusItem.menu?.items = [
            NSMenuItem(title: "Start", systemSymbolName: "play.fill", action: #selector(startAction)),
            NSMenuItem(title: "Stop", systemSymbolName: "stop.fill", action: #selector(stopAction)),
            NSMenuItem(title: "Pause", systemSymbolName: "playpause.fill", action: #selector(toggleAction)),
//            NSMenuItem(title: "Pause", systemSymbolName: "pause.fill", action: #selector(toggleAction)),
            NSMenuItem(title: "Skip Backward", systemSymbolName: "gobackward", action: #selector(backwardAction)),
            NSMenuItem(title: "Skip Forward", systemSymbolName: "goforward", action: #selector(forwardAction)),
            .separator(),
            NSMenuItem(title: "Preferences...", action: Selector(("showPreferencesWindow:")), keyEquivalent: ","),
            NSMenuItem(title: "Quit", action: #selector(NSApplication.shared.terminate), keyEquivalent: "q"),
        ]

        setupNowPlayingRemoteCommands()

        NSApplication.shared.servicesProvider = self
        NSUpdateDynamicServices()
        
#if DEBUG
//        Defaults.removeAll()
//        print("write")
//        Defaults[.pronunciations] = [
//            .init(search: "text", replace: "string"),
//            .init(search: "test", replace: "whaaaat"),
//            .init(search: "from", replace: "to"),
//        ]
//        print("read")
//        print(Defaults[.pronunciations])
//        print(Pronunciation.getVoiceOverPronunciations())
//        easyReader.pronunciations = Defaults[.pronunciations]
//        if let pronunciations = Pronunciation.getVoiceOverPronunciations() {
//            easyReader.pronunciations.append(contentsOf: pronunciations)
//        }
//        if let pronunciations = Pronunciation.getVoiceOverPronunciations() {
//            Defaults[.pronunciations].append(contentsOf: pronunciations)
//        }
//        print(Defaults[.pronunciations])

//        easyReader.delegate?.easyReader(easyReader, didChangeState: .reading)
//        easyReader.delegate?.easyReader(easyReader, didChangeState: .stopped)
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Test View"
        window.makeKeyAndOrderFront(nil)
        window.center()
        let scrollView = NSTextView.scrollableTextView()
        guard let textView: NSTextView = scrollView.documentView as? NSTextView else { return }
        textView.string = "This is some testing text... and it's gotta be pretty long, in order to test things well. So I guess we'll see how well it works\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\nWe need lots of stuff to make it scrollable\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\nDoes it work?\n\n\n\n\n\nI hope so"
        window.contentView = scrollView
        window.makeFirstResponder(textView)
//        easyReader.readable = ReadableTextView(textView)
//        _ = easyReader.start()
#endif
    }
    
//    @objc func openSettings() {
//        NSApplication.shared.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
//    }
    
//    @objc func toggleActivation() {
//        switch NSApplication.shared.activationPolicy() {
//        case .regular:
//            NSApplication.shared.setActivationPolicy(.prohibited)
//            NSApplication.shared.activate(ignoringOtherApps: true)
//        case .prohibited:
//            NSApplication.shared.setActivationPolicy(.regular)
//            NSApplication.shared.activate(ignoringOtherApps: true)
////        case .prohibited: break
//        default: break
//        }
//    }
    
    @objc func startAction() {
        guard easyReader.startReadingFrontmostApplication() else {
            NSSound.beep()
            return
        }
    }
    
    @objc func stopAction() {
        guard easyReader.stop() else {
            NSSound.beep()
            return
        }
    }
    
    @objc func toggleAction() {
        guard easyReader.togglePauseResume() else {
            NSSound.beep()
            return
        }
    }
    
    @objc func backwardAction() {
        guard easyReader.skip(.backward) else {
            NSSound.beep()
            return
        }
    }
    
    @objc func forwardAction() {
        guard easyReader.skip(.forward) else {
            NSSound.beep()
            return
        }
    }
    
//    @objc func startServiceHandler(_ pboard: NSPasteboard, userData: String, error: NSErrorPointer) {
//        print("SERVICE: start \(pboard.types)")
//        startAction()
//    }
//
//    @objc func stopServiceHandler(_ pboard: NSPasteboard, userData: String, error: NSErrorPointer) {
//        print("SERVICE: stop \(pboard.types)")
//        stopAction()
//    }
    
//    TODO: make sure that you either can't call start if it's reading, or that it will toggle start/stop, or it will cancel a current session
//    TODO: maybe rename to something like easyReaderServicesHandler
    @objc func servicesHandler(_ pboard: NSPasteboard, userData: String, error: NSErrorPointer) {
        print("SERVICE: \(userData) \(pboard.types as Any)")
        switch userData {
            case "start": startAction()
            case "stop": stopAction()
            case "toggle": toggleAction()
//            case "play/pause": toggleAction()
//            case "pause/resume": toggleAction()
            case "backward": backwardAction()
            case "forward": forwardAction()
            default: break
        }
    }
    
    
    
//    TODO: cleanup these functions
    func setupNowPlayingRemoteCommands() {
        print("setting up remote commands")

//        TODO: add NSSound.beep()?
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.addTarget { [weak self] event in
            print("play \(event.command)")
            guard let self else { return .commandFailed }
//            guard self.easyReader.resume() || self.easyReader.startReadingFrontmostApplication() else { return .noSuchContent }
            guard self.easyReader.resume() else { return .noSuchContent }
            return .success
        }
        commandCenter.pauseCommand.addTarget { [weak self] event in
            print("pause \(event.command)")
            guard let self else { return .commandFailed }
            guard self.easyReader.pause() else { return .commandFailed }
            return .success
        }
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] event in
            print("toggle \(event.command)")
            guard let self else { return .commandFailed }
//            guard self.easyReader.togglePauseResume() || self.easyReader.startReadingFrontmostApplication() else { return .noSuchContent }
            guard self.easyReader.togglePauseResume() else { return .noSuchContent }
            return .success
        }
        commandCenter.stopCommand.addTarget { [weak self] event in
            print("stop \(event.command)")
            guard let self else { return .commandFailed }
            guard self.easyReader.stop() else { return .commandFailed }
            return .success
        }

//        commandCenter.changePlaybackRateCommand.addTarget { [weak self] event in
//            print("change rate \(event.command)")
//            guard let self else { return .commandFailed }
//            self.easyReader.rate = Float(event.timestamp)
//            return .success
//        }
//        commandCenter.changePlaybackPositionCommand
//        commandCenter.skipBackwardCommand.preferredIntervals = [1]
//        commandCenter.skipBackwardCommand.addTarget
//        commandCenter.skipForwardCommand.preferredIntervals = [1]
//        commandCenter.skipForwardCommand.addTarget

        commandCenter.previousTrackCommand.addTarget { [weak self] event in
            guard let self else { return .commandFailed }
            guard self.easyReader.skip(.backward) else { return .noSuchContent }
//            guard self.easyReader.skip(.backward) else { return .commandFailed }
            return .success
        }
        commandCenter.nextTrackCommand.addTarget { [weak self] event in
            guard let self else { return .commandFailed }
            guard self.easyReader.skip(.forward) else { return .noSuchContent }
//            guard self.easyReader.skip(.forward) else { return .commandFailed }
            return .success
        }
    }

    func updateNowPlayingItemMetadata() {
//        MPMediaItem
        var info = [String: Any]()
//        info[MPMediaItemPropertyMediaType] = MPNowPlayingInfoMediaType.audio
//        info[MPMediaItemPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
//        info[MPMediaItemPropertyMediaType] = MPMediaType.audioBook
//        info[MPMediaItemPropertyMediaType] = MPMediaType.audioBook.rawValue
//        info[MPMediaItemPropertyMediaType] = NSNumber(value: MPMediaType.audioBook.rawValue)
//        info[MPMediaItemPropertyMediaType] = MPMediaType.anyAudio.rawValue
//        info[MPMediaItemPropertyMediaType] = MPMediaType.podcast.rawValue
        info[MPMediaItemPropertyMediaType] = MPMediaType.audioBook.rawValue
        if let title = easyReader.readable?.title {
            info[MPMediaItemPropertyTitle] = title
        }
        if let groupTitle = easyReader.readable?.groupTitle {
            info[MPMediaItemPropertyAlbumTitle] = groupTitle
        }
        if let appName = NSRunningApplication.current.localizedName {
            info[MPMediaItemPropertyArtist] = appName
        }
        if let icon = easyReader.readable?.icon {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: icon.size) { _ in return icon }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    
    func updateNowPlayingPlaybackInfo() {
//        MPNowPlayingInfo
        let infoCenter = MPNowPlayingInfoCenter.default()
        var info = infoCenter.nowPlayingInfo ?? [String: Any]()
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
//        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = 3
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 0.5
        info[MPNowPlayingInfoPropertyPlaybackRate] = easyReader.rate
        infoCenter.nowPlayingInfo = info
    }
    
    func updateNowPlayingInfo(state: EasyReader.State) {
//        TODO: do we need to enable/disable any commands?
//        let commandCenter = MPRemoteCommandCenter.shared()
        let infoCenter = MPNowPlayingInfoCenter.default()
        switch state {
            case .reading:
                infoCenter.playbackState = .playing
                updateNowPlayingItemMetadata()
                updateNowPlayingPlaybackInfo()
            case .stopped:
                infoCenter.playbackState = .stopped
//                infoCenter.nowPlayingInfo = [:]
                infoCenter.nowPlayingInfo = nil
            case .paused:
                infoCenter.playbackState = .paused
//            case .error:
//                infoCenter.playbackState = .interrupted
            default:
                infoCenter.playbackState = .unknown
        }
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
            case #selector(startAction): return easyReader.state == .stopped
            case #selector(stopAction): return easyReader.state != .stopped
            case #selector(toggleAction):
                menuItem.title = easyReader.state == .paused ? "Resume" : "Pause"
//                toggleMenu.image = NSImage(systemSymbolName: easyReader.state == .paused ? "play.fill" : "pause.fill", accessibilityDescription: nil)
                return easyReader.state != .stopped
            case #selector(backwardAction): return easyReader.state != .stopped
            case #selector(forwardAction): return easyReader.state != .stopped
            case nil: return false
            default: return true
        }
    }
}

extension AppDelegate: EasyReaderDelegate {
    func easyReader(_ reader: EasyReader, didChangeState state: EasyReader.State) {
        updateNowPlayingInfo(state: state)
        if let imageName = readerStateImages[state], let image = NSImage(systemSymbolName: imageName, accessibilityDescription: nil) {
            statusItem.button?.image = image
        } else {
            statusItem.button?.image = readerStateImageDefault
        }
//        switch state {
//            case .error:
//                statusItem.button?.image = NSImage(systemSymbolName: "waveform.badge.exclamationmark", accessibilityDescription: nil)
//            default:
//                statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)
//        }
        statusItem.menu?.update()
//        if state == .error {
//            NSSound.beep()
//        }
    }
}

extension NSMenuItem {
    convenience init(title: String, systemSymbolName: String, action: Selector?, keyEquivalent: String = "") {
        self.init(title: title, action: action, keyEquivalent: keyEquivalent)
        image = NSImage(systemSymbolName: systemSymbolName, accessibilityDescription: nil)
    }
}
