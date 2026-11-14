import SwiftUI
import Defaults
import KeyboardShortcuts

@main
struct EasyReaderApp: App {
    @NSApplicationDelegateAdaptor var appDelegate: AppDelegate

    var body: some Scene {
        #if DEBUG
            WindowGroup {
                ContentView()
            }
        #endif
        Settings {
            SettingsView()
        }
    }
}

/// Opens the SwiftUI `Settings` scene from AppKit.
@MainActor
final class SettingsOpener: NSObject {
    static var window: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" }
    }

    @objc static func open() {
        // An accessory app isn't activated by opening a window. Not `activate()`: it's declined without a user event.
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

    // The selectors above only log a warning on macOS 14+.
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

    func applicationDidFinishLaunching(_ notification: Notification) {
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
            NSMenuItem(title: "About EasyReader", action: #selector(aboutAction), keyEquivalent: ""),
            {
                let menuItem = NSMenuItem(title: "Settings…", action: #selector(SettingsOpener.open), keyEquivalent: ",")
                menuItem.target = SettingsOpener.self
                if #unavailable(macOS 13.0) {
                    menuItem.title = "Preferences…"
                }
                return menuItem
            }(),
            NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
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
            for await _ in Defaults.updates([.speechVoice, .speechVolume, .speechRate, .speechPitch], initial: false) {
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
                if !easyReader.start(reading: .frontmostApp) { NSSound.beep() }
            case .reading:
                if !easyReader.stop() { NSSound.beep() }
        }
    }

    @objc func togglePlayPauseAction() {
        Log.app.debug("toggle play/pause (state \(easyReader.state))")
        if !easyReader.togglePlayPause() { NSSound.beep() }
    }

    @objc func skipForwardAction() {
        Log.app.debug("skip forward")
        if !easyReader.skip(.forward) { NSSound.beep() }
    }

    @objc func skipBackwardAction() {
        Log.app.debug("skip backward")
        if !easyReader.skip(.backward) { NSSound.beep() }
    }

    @objc func aboutAction() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
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
