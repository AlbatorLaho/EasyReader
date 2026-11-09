//
//  EasyReaderApp.swift
//  EasyReader
//
//  Created by Ewalk on 24/11/2.
//

import SwiftUI
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
//                        guard appDelegate.easyReader.togglePlayPause() else {
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

/// Opens the settings window (the SwiftUI `Settings` scene) from AppKit, e.g. the status item's menu.
@MainActor
final class SettingsOpener: NSObject {
    /// The settings window, once it was opened.
    static var window: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" }
    }

    /// Opens the settings window, or brings it to the front if it's already open. An accessory app opening a window
    /// isn't activated (the window opens behind the frontmost app, or nothing happens if it's already open), so
    /// activate first. Not the cooperative `activate()` (macOS 14+): it was declined in tests (no user event).
    @objc static func open() {
        NSApp.activate(ignoringOtherApps: true)
        if #available(macOS 14.0, *) {
            Modern.openSettings()
        } else if #available(macOS 13.0, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
        window?.makeKeyAndOrderFront(nil)
    }

    /// `openSettings` (macOS 14+; the selectors above only log a warning there), read outside a view.
    @available(macOS 14.0, *)
    @MainActor private enum Modern {
        @Environment(\.openSettings) static var openSettings
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var easyReader: EasyReader!
    var nowPlayingManager: NowPlayingManager!
    var statusItem: NSStatusItem!

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
#if DEBUG
        NSApplication.shared.setActivationPolicy(.regular)
#endif

        easyReader = EasyReader()
        easyReader.delegate = self
        nowPlayingManager = NowPlayingManager(reader: easyReader)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)
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
                let menuItem = NSMenuItem(title: "Skip Forward", action: #selector(skipForwardAction), keyEquivalent: "")
                menuItem.image = NSImage(systemSymbolName: "goforward", accessibilityDescription: nil)
                menuItem.setShortcut(for: .skipForward)
                KeyboardShortcuts.onKeyDown(for: .skipForward, action: skipForwardAction)
                return menuItem
            }(),
            {
                let menuItem = NSMenuItem(title: "Skip Backward", action: #selector(skipBackwardAction), keyEquivalent: "")
                menuItem.image = NSImage(systemSymbolName: "gobackward", accessibilityDescription: nil)
                menuItem.setShortcut(for: .skipBackward)
                KeyboardShortcuts.onKeyDown(for: .skipBackward, action: skipBackwardAction)
                return menuItem
            }(),
            .separator(),
            {
                let menuItem = NSMenuItem(title: "Settings...", action: #selector(SettingsOpener.open), keyEquivalent: ",")
                menuItem.target = SettingsOpener.self
                if #unavailable(macOS 13.0) {
                    menuItem.title = "Preferences..."
                }
                return menuItem
            }(),
            NSMenuItem(title: "Quit", action: #selector(NSApplication.shared.terminate), keyEquivalent: "q"),
        ]

        KeyboardShortcuts.onKeyDown(for: .increaseRate) {
            Defaults[.speechRate] = SpeechRate.adjusted(Defaults[.speechRate], byMultiplier: 0.1)
            Log.app.debug("shortcut: increase rate → \(Defaults[.speechRate])")
        }
        KeyboardShortcuts.onKeyDown(for: .decreaseRate) {
            Defaults[.speechRate] = SpeechRate.adjusted(Defaults[.speechRate], byMultiplier: -0.1)
            Log.app.debug("shortcut: decrease rate → \(Defaults[.speechRate])")
        }
        KeyboardShortcuts.onKeyDown(for: .defaultRate) {
            Defaults.reset(.speechRate)
            Log.app.debug("shortcut: reset rate → \(Defaults[.speechRate])")
        }

        Task {
            for await _ in Defaults.updates([
                .speechVoice,
                .speechVolume,
                .speechRate,
                .speechPitch,
            ], initial: false) {
                Log.settings.debug("speech settings changed (state \(easyReader.state))")
                guard easyReader.state == .reading else { continue }
                easyReader.play(from: .word)
            }
        }
        Task {
            for await value in Defaults.updates(.selectionUnit) {
                Log.settings.debug("selection unit: \(value)")
                easyReader.textSelector = NLTextSelector(unit: value)
            }
        }
        Task {
            for await value in Defaults.updates(.nowPlayingCenterIntegration) {
                Log.settings.debug("Now Playing integration: \(value)")
                nowPlayingManager.isEnabled = value
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        easyReader?.prepareForTermination()
    }

    @objc func toggleStartStopAction() {
        Log.app.debug("toggle start/stop (state \(easyReader.state))")
        switch easyReader.state {
            case .stopped, .paused:
                // Paused: resumes if the frontmost element is the one being read, else starts on it.
                guard easyReader.start(reading: .frontmostApp) else {
                    NSSound.beep()
                    return
                }
            case .reading:
                guard easyReader.stop() else {
                    NSSound.beep()
                    return
                }
        }
    }

    @objc func togglePlayPauseAction() {
        Log.app.debug("toggle play/pause (state \(easyReader.state))")
        guard easyReader.togglePlayPause() else {
            NSSound.beep()
            return
        }
    }
    
    @objc func skipForwardAction() {
        Log.app.debug("skip forward")
        guard easyReader.skip(.forward) else {
            NSSound.beep()
            return
        }
    }

    @objc func skipBackwardAction() {
        Log.app.debug("skip backward")
        guard easyReader.skip(.backward) else {
            NSSound.beep()
            return
        }
    }
}

extension AppDelegate: EasyReaderDelegate {
    func easyReader(_ reader: EasyReader, didChangeState state: EasyReader.State) {
        nowPlayingManager.update(readable: easyReader.readable, state: state)
        statusItem.menu?.update()
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
            case #selector(toggleStartStopAction):
                menuItem.title = easyReader.state == .reading ? "Stop" : "Start"
                menuItem.image = NSImage(systemSymbolName: easyReader.state == .reading ? "stop.fill" : "play.fill", accessibilityDescription: nil)
                return true
            case #selector(togglePlayPauseAction):
                menuItem.title = easyReader.state == .paused ? "Resume" : "Pause"
                menuItem.image = NSImage(systemSymbolName: easyReader.state == .paused ? "play.fill" : "pause.fill", accessibilityDescription: nil)
                return easyReader.state != .stopped
            case #selector(skipForwardAction): return easyReader.state != .stopped && easyReader.canSkipForward
            case #selector(skipBackwardAction): return easyReader.state != .stopped
            case nil: return false
            default: return true
        }
    }
}
