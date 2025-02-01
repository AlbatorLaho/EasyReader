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
import KeyboardShortcuts

@main
struct EasyReaderApp: App {
    @NSApplicationDelegateAdaptor var appDelegate: AppDelegate
//    @Environment(\.openSettings) private var openSettings
//    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase

//    init() {
//        NSApplication.shared.setActivationPolicy(.accessory)
//        NSApplication.shared.setActivationPolicy(.prohibited)
//    }

    var body: some Scene {
#if DEBUG
        WindowGroup {
            ContentView()
        }
#endif
//        if #available(macOS 13.0, *) {
//            MenuBarExtra("EasyReader", systemImage: "waveform") {
//                Group {
//                    Button("Start", systemImage: "play.fill") {
//                        guard let app = NSWorkspace.shared.frontmostApplication, appDelegate.easyReader.start(reading: app) else {
//                            NSSound.beep()
//                            return
//                        }
//                    }
//                    Button("Stop", systemImage: "stop.fill") {
//                        guard appDelegate.easyReader.stop() else {
//                            NSSound.beep()
//                            return
//                        }
//                    }
//                    Button("Pause/Resume", systemImage: "playpause.fill") {
//                        guard appDelegate.easyReader.togglePauseResume() else {
//                            NSSound.beep()
//                            return
//                        }
//                    }
//                    Button("Skip Backward", systemImage: "gobackward") {
//                        guard appDelegate.easyReader.skip(.backward) else {
//                            NSSound.beep()
//                            return
//                        }
//                    }
//                    Button("Skip Forward", systemImage: "goforward") {
//                        guard appDelegate.easyReader.skip(.forward) else {
//                            NSSound.beep()
//                            return
//                        }
//                    }
//
//                    Divider()
//
//                    if #available(macOS 14.0, *) {
////                        FIXME: doesn't work when activation is prohibited
//                        SettingsLink()
//                            .keyboardShortcut(",")
//                            .labelStyle(.titleOnly)
////                            .labelStyle(.automatic)
//                    }
//                    Button("Quit") {
//                        NSApplication.shared.terminate(nil)
//                    }
//                    .keyboardShortcut("q")
//                }
//                .labelStyle(.titleAndIcon)
//            }
//        }
        Settings {
            SettingsView()
//                .textFieldStyle(.roundedBorder)
//                .onExitCommand() {
////                    TODO: close settings?
//                    print("onExitCommand")
//                }
//                .onAppear() {
//                    print("onAppear")
//                    NSApplication.shared.setActivationPolicy(.regular)
//                    if #available(macOS 14.0, *) {
//                        NSApplication.shared.activate()
//                    } else {
//                        NSApplication.shared.activate(ignoringOtherApps: true)
//                    }
//                }
//                .onDisappear() {
//                    print("onDisappear")
//                    NSApplication.shared.setActivationPolicy(.accessory)
//                    NSApplication.shared.deactivate()
//                }
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
    ]

    @available(macOS 14.0, *)
    private final class SettingsOpener: ObservableObject {
        @Environment(\.openSettings) static private var openSettings

        @objc static func open() {
            openSettings()
        }
    }

//    TODO: use .prohibited unless a window needs to be opened, then use .accessory or .regular (make sure the permisions dialog can be opened)
    func applicationWillFinishLaunching(_ notification: Notification) {
//#if !DEBUG
//        NSApplication.shared.setActivationPolicy(.regular)
//        NSApplication.shared.setActivationPolicy(.accessory)
//        NSApplication.shared.setActivationPolicy(.prohibited)
//#endif
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
//        NSApplication.shared.setActivationPolicy(.accessory)

        easyReader = EasyReader()
        easyReader.textSelector = NLTextSelector(unit: .sentence)
        easyReader.delegate = self
        nowPlayingManager = NowPlayingManager()
        nowPlayingManager.delegate = self

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = readerStateImageDefault
        statusItem.menu = NSMenu()
        statusItem.menu?.items = [
            {
                let menuItem = NSMenuItem()
                menuItem.action = #selector(toggleStartStopAction)
                menuItem.setShortcut(for: .toggleStartStop)
                KeyboardShortcuts.onKeyDown(for: .toggleStartStop, action: toggleStartStopAction)
                return menuItem
            }(),
            {
                let menuItem = NSMenuItem()
                menuItem.action = #selector(togglePlayPauseAction)
                menuItem.setShortcut(for: .togglePlayPause)
                KeyboardShortcuts.onKeyDown(for: .togglePlayPause, action: togglePlayPauseAction)
                return menuItem
            }(),
            {
                let menuItem = NSMenuItem(title: "Skip Backward", action: #selector(skipBackwardAction), keyEquivalent: "")
                menuItem.image = NSImage(systemSymbolName: "gobackward", accessibilityDescription: nil)
                menuItem.setShortcut(for: .skipBackward)
                KeyboardShortcuts.onKeyDown(for: .skipBackward, action: skipBackwardAction)
                return menuItem
            }(),
            {
                let menuItem = NSMenuItem(title: "Skip Forward", action: #selector(skipForwardAction), keyEquivalent: "")
                menuItem.image = NSImage(systemSymbolName: "goforward", accessibilityDescription: nil)
                menuItem.setShortcut(for: .skipForward)
                KeyboardShortcuts.onKeyDown(for: .skipForward, action: skipForwardAction)
                return menuItem
            }(),
            .separator(),
            {
                let menuItem = NSMenuItem(title: "Settings...", action: nil, keyEquivalent: ",")
                if #available(macOS 14.0, *) {
                    menuItem.target = SettingsOpener.self
                    menuItem.action = #selector(SettingsOpener.open)
                } else if #available(macOS 13.0, *) {
                    menuItem.action = Selector(("showSettingsWindow:"))
                } else {
                    menuItem.title = "Preferences..."
                    menuItem.action = Selector(("showPreferencesWindow:"))
                }
                return menuItem
            }(),
            NSMenuItem(title: "Quit", action: #selector(NSApplication.shared.terminate), keyEquivalent: "q"),
        ]
    }

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

    @objc func toggleStartStopAction() {
        switch easyReader.state {
            case .stopped: startAction()
            case .reading: stopAction()
            case .paused:
                stopAction()
                startAction()
        }
    }

    @objc func togglePlayPauseAction() {
        guard easyReader.togglePauseResume() else {
            NSSound.beep()
            return
        }
    }
    
    @objc func skipBackwardAction() {
        guard easyReader.skip(.backward) else {
            NSSound.beep()
            return
        }
    }
    
    @objc func skipForwardAction() {
        guard easyReader.skip(.forward) else {
            NSSound.beep()
            return
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
        nowPlayingManager.updateInfo(easyReader.readable, state: Defaults[.useNowPlayingCenter] ? state : .stopped)
        if let imageName = readerStateImages[state], let image = NSImage(systemSymbolName: imageName, accessibilityDescription: nil) {
            statusItem.button?.image = image
        } else {
            statusItem.button?.image = readerStateImageDefault
        }
        statusItem.menu?.update()
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
            case #selector(toggleStartStopAction):
                menuItem.title = easyReader.state == .stopped ? "Start" : "Stop"
                menuItem.image = NSImage(systemSymbolName: easyReader.state == .stopped ? "play.fill" : "stop.fill", accessibilityDescription: nil)
                return true
            case #selector(togglePlayPauseAction):
                menuItem.title = easyReader.state == .paused ? "Resume" : "Pause"
                menuItem.image = NSImage(systemSymbolName: easyReader.state == .paused ? "play.fill" : "pause.fill", accessibilityDescription: nil)
                return easyReader.state != .stopped
            case #selector(skipBackwardAction): return easyReader.state != .stopped
            case #selector(skipForwardAction): return easyReader.state != .stopped
            case nil: return false
            default: return true
        }
    }
}

//extension NSMenuItem {
//    convenience init(title: String, systemSymbolName: String, action: Selector?, keyEquivalent: String = "") {
//        self.init(title: title, action: action, keyEquivalent: keyEquivalent)
//        image = NSImage(systemSymbolName: systemSymbolName, accessibilityDescription: nil)
//    }
//}
