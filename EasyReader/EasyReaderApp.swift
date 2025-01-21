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
    var nowPlayingManager: NowPlayingManager!
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
        nowPlayingManager = NowPlayingManager()
        nowPlayingManager.delegate = self

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

        nowPlayingManager.setupRemoteCommands()

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
        guard let app = NSWorkspace.shared.frontmostApplication, easyReader.start(reading: app) else {
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
}

//TODO: use commandFailed, noSuchContent, and noActionableNowPlayingItem?
extension AppDelegate: NowPlayingManagerDelegate {
    func play(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        return easyReader.start() ? .success : .commandFailed
    }
    func stop(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        return easyReader.stop() ? .success : .commandFailed
    }
    func pause(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        return easyReader.pause() ? .success : .commandFailed
    }
    func togglePlayPause(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        return easyReader.togglePauseResume() ? .success : .commandFailed
    }

    func nextTrack(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        return easyReader.skip(.forward) ? .success : .commandFailed
    }
    func previousTrack(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        return easyReader.skip(.backward) ? .success : .commandFailed
    }
//    func skipForward(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
//        return .success
//    }
//    func skipBackward(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
//        return .success
//    }
//    func seekForward(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
//        return .success
//    }
//    func seekBackward(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
//        return .success
//    }

//    func changePlaybackRate(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
//        return .success
//    }
//    func changePlaybackPosition(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
//        return .success
//    }
}

extension AppDelegate: EasyReaderDelegate {
    func easyReader(_ reader: EasyReader, didChangeState state: EasyReader.State) {
        nowPlayingManager.updateInfo(easyReader.readable, state: state)
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

extension NSMenuItem {
    convenience init(title: String, systemSymbolName: String, action: Selector?, keyEquivalent: String = "") {
        self.init(title: title, action: action, keyEquivalent: keyEquivalent)
        image = NSImage(systemSymbolName: systemSymbolName, accessibilityDescription: nil)
    }
}
