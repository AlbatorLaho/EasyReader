//
//  EasyReaderApp.swift
//  EasyReader
//
//  Created by Ewalk on 24/11/2.
//

import SwiftUI
import MediaPlayer
import Defaults

@main
struct EasyReaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
//    @Environment(\.openSettings) private var openSettings
//    @Environment(\.openWindow) private var openWindow

    init() {
//        NSApplication.shared.setActivationPolicy(.accessory)
//        NSApplication.shared.setActivationPolicy(.prohibited)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(appDelegate: appDelegate)
        }
        Settings {
            EmptyView()
//            SettingsView()
        }
    }
}

//struct SettingsView: View {
//    @AppStorage("showPreview") private var showPreview = true
//    @AppStorage("fontSize") private var fontSize = 12.0
//
//    var body: some View {
//        Form {
//            Toggle("Show Previews", isOn: $showPreview)
//            Slider(value: $fontSize, in: 9...96) {
//                Text("Font Size (\(fontSize, specifier: "%.0f") pts)")
//            }
//        }
//    }
//}
//struct SettingsView: View {
//    var body: some View {
//        TabView {
//            Tab("General", systemImage: "gear") {
//                GeneralSettingsView()
//            }
//            Tab("Advanced", systemImage: "star") {
//                AdvancedSettingsView()
//            }
//        }
//        .scenePadding()
//        .frame(maxWidth: 350, minHeight: 100)
//    }
//}

//struct SettingsView: View {
//    @Default(.useSystemVoice) var useSystemVoice
//    @Default(.voiceIdentifier) var voiceIdentifier
////    @Default(.pronunciations) var pronunciations
////    let speechVoices = AVSpeechSynthesisVoice.speechVoices().map({ $0.identifier })
//    @State private var pronunciations: [Pronunciation] = [
//        .init(domain: nil, search: "from", replace: "to", options: .caseInsensitive, enabled: true),
//        .init(domain: "com.apple.finder", search: "1from", replace: "1to", options: .caseInsensitive, enabled: true),
//        .init(domain: "com.apple.finder", search: "2from", replace: "2to", options: [], enabled: true),
//        .init(domain: "com.apple.finder", search: "3from", replace: "3to", options: .caseInsensitive, enabled: true),
//        .init(domain: "com.apple.finder", search: "4from", replace: "4to", options: .caseInsensitive, enabled: false),
//        .init(domain: "com.apple.finder", search: "5from", replace: "5to", options: .caseInsensitive, enabled: true),
//    ]
//    @State private var selectedVoice: AVSpeechSynthesisVoice?
//    @State private var voices: [AVSpeechSynthesisVoice] = []
//
//    var body: some View {
//        Form {
//            Toggle("Use System Voice", isOn: $useSystemVoice)
//            Defaults.Toggle("Use System Voice", key: .useSystemVoice)
//
//            Picker("Select Voice:", selection: $selectedVoice) {
//                Text("System Voice (TEST)")
//                    .tag(nil as AVSpeechSynthesisVoice?)
//                Divider()
//                ForEach(voices, id: \.identifier) { voice in
//                    Text("\(voice.name) (\(voice.language))")
//                        .tag(voice as AVSpeechSynthesisVoice?)
//                }
//            }
//            .onAppear() {
//                voices = AVSpeechSynthesisVoice.speechVoices()
//            }
////            if let selectedVoice = selectedVoice {
////                Text("Selected: \(selectedVoice.name) (\(selectedVoice.language))")
////            }
//
//            List {
//                ForEach($pronunciations, id: \.search) { pronunciation in
//                    HStack {
//                        TextField("Search", text: pronunciation.search)
//                        TextField("Replace", text: pronunciation.replace)
//                        Picker("App", selection: pronunciation.domain) {}
//                        Toggle("Enable", isOn: pronunciation.enabled)
//                    }
//                }
//            }
//
////            Button("Reset to defaults") {
////                _useSystemVoice.reset()
////            }
//        }
//        .padding()
//    }
//}
//
//struct SettingsView_Previews: PreviewProvider {
//    static var previews: some View {
//        SettingsView()
//    }
//}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let easyReader = EasyReader()
    var statusItem: NSStatusItem!
//    TODO: handle these better
    var readerStateImageDefault: NSImage = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)!
    var readerStateImages: [EasyReader.State: String] = [
//        .stopped: "waveform",
        .stopped: "waveform.slash",
//        .paused: "waveform",
//        .reading: "waveform",
        .error: "waveform.badge.exclamationmark",
    ]
    
//    TODO: use .prohibited unless a window needs to be opened, then use .accessory or .regular (make sure the permisions dialog can be opened)
    func applicationWillFinishLaunching(_ notification: Notification) {
//        NSApplication.shared.setActivationPolicy(.prohibited)
//        NSApplication.shared.setActivationPolicy(.accessory)
//        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        easyReader.textSelector = NLTextSelector(unit: .sentence)
        let startMenu = NSMenuItem(title: "Start", action: #selector(startAction), keyEquivalent: "")
        let stopMenu = NSMenuItem(title: "Stop", action: #selector(stopAction), keyEquivalent: "")
        let toggleMenu = NSMenuItem(title: "Play/Pause", action: #selector(toggleAction), keyEquivalent: "")
        let backwardMenu = NSMenuItem(title: "Skip Backward", action: #selector(backwardAction), keyEquivalent: "")
        let forwardMenu = NSMenuItem(title: "Skip Forward", action: #selector(forwardAction), keyEquivalent: "")
        startMenu.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
        stopMenu.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: nil)
        toggleMenu.image = NSImage(systemSymbolName: "playpause.fill", accessibilityDescription: nil)
//        toggleMenu.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: nil)
        backwardMenu.image = NSImage(systemSymbolName: "gobackward", accessibilityDescription: nil)
        forwardMenu.image = NSImage(systemSymbolName: "goforward", accessibilityDescription: nil)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = NSMenu()
        statusItem.menu?.items = [
            startMenu,
            stopMenu,
            toggleMenu,
            backwardMenu,
            forwardMenu,
            .separator(),
            NSMenuItem(title: "Preferences...", action: Selector(("showPreferencesWindow:")), keyEquivalent: ","),
            NSMenuItem(title: "Quit", action: #selector(NSApplication.shared.terminate), keyEquivalent: "q"),
        ]

        setupRemoteCommands()
//        updateNowPlayingItemMetadata()
//        updateNowPlayingPlaybackInfo()

        easyReader.delegate = self
        easyReader.delegate?.easyReader(easyReader, didChangeState: .reading)
        easyReader.delegate?.easyReader(easyReader, didChangeState: .stopped)
//        updateNowPlayingItemMetadata()
//        updateNowPlayingPlaybackInfo()
//        let infoCenter = MPNowPlayingInfoCenter.default()
//        infoCenter.playbackState = .playing
//        infoCenter.playbackState = .stopped

        NSApplication.shared.servicesProvider = self
        NSUpdateDynamicServices()
        
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
    }
    
//    @objc func openSettings() {
//        NSApplication.shared.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
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
    func setupRemoteCommands() {
        print("setting up remote commands")

//        TODO: add NSSound.beep()?
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.addTarget { [weak self] event in
            print("play \(event.command)")
            guard let self = self else { return .commandFailed }
            guard self.easyReader.resume() || self.easyReader.startReadingFrontmostApplication() else { return .noSuchContent }
            return .success
        }
        commandCenter.pauseCommand.addTarget { [weak self] event in
            print("pause \(event.command)")
            guard let self = self else { return .commandFailed }
            guard self.easyReader.pause() else { return .commandFailed }
            return .success
        }
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] event in
            print("toggle \(event.command)")
            guard let self = self else { return .commandFailed }
            guard self.easyReader.togglePauseResume() || self.easyReader.startReadingFrontmostApplication() else { return .noSuchContent }
            return .success
        }
        commandCenter.stopCommand.addTarget { [weak self] event in
            print("stop \(event.command)")
            guard let self = self else { return .commandFailed }
            guard self.easyReader.stop() else { return .commandFailed }
            return .success
        }

//        commandCenter.changePlaybackRateCommand.addTarget { [weak self] event in
//            print("change rate \(event.command)")
//            guard let self = self else { return .commandFailed }
//            self.easyReader.rate = Float(event.timestamp)
//            return .success
//        }
//        commandCenter.changePlaybackPositionCommand
//        commandCenter.skipBackwardCommand.preferredIntervals = [1]
//        commandCenter.skipBackwardCommand.addTarget
//        commandCenter.skipForwardCommand.preferredIntervals = [1]
//        commandCenter.skipForwardCommand.addTarget

        commandCenter.previousTrackCommand.addTarget { [weak self] event in
            guard let self = self else { return .commandFailed }
            guard self.easyReader.skip(.backward) else { return .noSuchContent }
//            guard self.easyReader.skip(.backward) else { return .commandFailed }
            return .success
        }
        commandCenter.nextTrackCommand.addTarget { [weak self] event in
            guard let self = self else { return .commandFailed }
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
//        info[MPNowPlayingInfoPropertyPlaybackRate] = easyReader.rate
        info[MPNowPlayingInfoPropertyPlaybackRate] = easyReader.utterance?.rate
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
//                MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
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
