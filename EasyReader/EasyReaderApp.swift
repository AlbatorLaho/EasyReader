import AVFoundation
import SwiftUI
import Defaults
import KeyboardShortcuts

@main
struct EasyReaderApp: App {
    @NSApplicationDelegateAdaptor var appDelegate: AppDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { ReaderWindow.openDocument() }
                    .keyboardShortcut("o")
                Button("Open URL…") { ReaderWindow.openWebPage() }
                    .keyboardShortcut("l")
            }
        }
    }
}

/// Opens the SwiftUI `Settings` scene from AppKit.
@MainActor
final class SettingsOpener: NSObject {
    private nonisolated static let windowID = "com_apple_SwiftUI_Settings_window"

    static var window: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == windowID }
    }

    /// The policy without the settings window.
    static var restingPolicy: NSApplication.ActivationPolicy {
        Defaults[.appPresence] == .menuBar ? .accessory : .regular
    }

    /// Windows that keep the Dock icon while open.
    private nonisolated static let windowIDs: Set = [windowID, ReaderWindow.windowID]

    private static var hasOpenWindow: Bool {
        NSApp.windows.contains { $0.isVisible && windowIDs.contains($0.identifier?.rawValue ?? "") }
    }

    private static var closeObserver: NSObjectProtocol?

    @objc static func open() {
        // A Dock icon while open, so the window can be found with ⌘-Tab and the Dock
        NSApp.setActivationPolicy(.regular)
        observeClose()
        // Closing the window hid an accessory app, and a hidden app's windows stay hidden.
        NSApp.unhide(nil)
        if #available(macOS 14.0, *) {
            // Also activates the app, after the policy change, so it's first in ⌘-Tab.
            Modern.openSettings()
            // Read outside a view, which SwiftUI doesn't promise to support → the app menu's item if no window shows.
            Task {
                try? await Task.sleep(seconds: 0.5)
                guard window?.isVisible != true else { return }
                Log.settings.error("openSettings opened no window, using the menu item")
                openWithMenuItem()
            }
        } else {
            if #available(macOS 13.0, *) {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } else {
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            }
            // Activated before the policy change lands, the app isn't put first in ⌘-Tab.
            Task {
                try? await Task.sleep(seconds: 0.1)
                NSApp.activate(ignoringOtherApps: true)
                window?.makeKeyAndOrderFront(nil)
            }
        }
        window?.makeKeyAndOrderFront(nil)
    }

    /// Shows one of the app's other windows the way `open` shows Settings; `then` runs once it's key (or after 1 s).
    static func present(_ window: NSWindow, then action: (@MainActor () -> Void)? = nil) {
        NSApp.setActivationPolicy(.regular)
        observeClose()
        NSApp.unhide(nil)
        window.makeKeyAndOrderFront(nil)
        // Activated before the policy change lands, the app isn't put first in ⌘-Tab.
        Task {
            try? await Task.sleep(seconds: 0.1)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            for _ in 0..<18 where !window.isKeyWindow {
                try? await Task.sleep(seconds: 0.05)
            }
            action?()
        }
    }

    private static func observeClose() {
        guard closeObserver == nil else { return }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { notification in
            nonisolated(unsafe) let window = notification.object
            MainActor.assumeIsolated {
                guard let window = window as? NSWindow, windowIDs.contains(window.identifier?.rawValue ?? "") else { return }
                // Still visible while it closes
                guard !NSApp.windows.contains(where: { $0 !== window && $0.isVisible && windowIDs.contains($0.identifier?.rawValue ?? "") })
                else { return }
                didClose()
            }
        }
    }

    static func applyRestingPolicy() {
        guard !hasOpenWindow else { return }
        NSApp.setActivationPolicy(restingPolicy)
    }

    private static func didClose() {
        guard NSApp.activationPolicy() != restingPolicy else { return }
        NSApp.setActivationPolicy(restingPolicy)
        // Hands focus back to the app the user came from instead of leaving no app frontmost
        if restingPolicy == .accessory { NSApp.hide(nil) }
    }

    /// SwiftUI's Settings… item in the app menu (⌘,), present even while the menu bar isn't shown.
    private static func openWithMenuItem() {
        guard let menu = NSApp.mainMenu?.items.first?.submenu,
            let index = menu.items.firstIndex(where: { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command })
        else { return Log.settings.error("No Settings menu item") }
        menu.performActionForItem(at: index)
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
    private(set) var statusItem: NSStatusItem?
    let statusMenu = NSMenu()
    private let dockMenu = NSMenu()
    let readerService = ReaderService()
    private let statusItemDropTarget = StatusItemDropTarget()
    private var isQuitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(SettingsOpener.restingPolicy)

        easyReader = EasyReader()
        easyReader.delegate = self
        nowPlayingManager = NowPlayingManager(reader: easyReader)
        ReaderWindow.reader = easyReader
        NSApp.servicesProvider = readerService
        NSUpdateDynamicServices()
        // Its first lookup takes ~450 ms.
        DispatchQueue.main.async { _ = AVSpeechSynthesisVoice.system }

        KeyboardShortcuts.onKeyDown(for: .toggleStartStop, action: toggleStartStopAction)
        KeyboardShortcuts.onKeyDown(for: .togglePlayPause, action: togglePlayPauseAction)
        KeyboardShortcuts.onKeyDown(for: .skipForward, action: skipForwardAction)
        KeyboardShortcuts.onKeyDown(for: .skipBackward, action: skipBackwardAction)
        KeyboardShortcuts.onKeyDown(for: .readSelectionInReaderWindow, action: readSelectionInReaderWindowAction)
        dockMenu.items = playbackMenuItems()
        statusMenu.items =
            playbackMenuItems() + [
                .separator(),
                {
                    let menuItem = NSMenuItem(title: "Open…", action: #selector(ReaderWindow.openDocument), keyEquivalent: "o")
                    menuItem.target = ReaderWindow.self
                    return menuItem
                }(),
                {
                    let menuItem = NSMenuItem(title: "Open URL…", action: #selector(ReaderWindow.openWebPage), keyEquivalent: "l")
                    menuItem.target = ReaderWindow.self
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
                NSMenuItem(title: "Quit", action: #selector(quitAction), keyEquivalent: "q"),
            ]
        updateStatusItem()

        KeyboardShortcuts.onKeyDown(for: .increaseRate) {
            Defaults[.speechRate] = SpeechRate.stepped(Defaults[.speechRate], by: 1)
            Log.app.debug("shortcut: increase rate → \(Defaults[.speechRate])")
        }
        KeyboardShortcuts.onKeyDown(for: .decreaseRate) {
            Defaults[.speechRate] = SpeechRate.stepped(Defaults[.speechRate], by: -1)
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
        Task {
            for await value in Defaults.updates(.appPresence, initial: false) {
                Log.settings.debug("app presence: \(value)")
                updateStatusItem()
                SettingsOpener.applyRestingPolicy()
            }
        }
        Task {
            for await value in Defaults.updates(.mediaKeysAfterFinishing, initial: false) {
                Log.settings.debug("media keys after finishing: \(value)")
                updateNowPlaying()
            }
        }
    }

    @objc private func quitAction() {
        isQuitting = true
        NSApp.terminate(nil)
    }

    // ⌘Q with windows open in a menu bar app can only close them. The status menu's Quit, and Apple events (logout, the Dock's Quit) quit.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isQuitting, Defaults[.quitClosesWindows], Defaults[.appPresence] == .menuBar, NSAppleEventManager.shared().currentAppleEvent == nil else {
            return .terminateNow
        }
        let windows = NSApp.windows.filter { $0.isVisible && $0.styleMask.contains(.titled) }
        guard !windows.isEmpty else { return .terminateNow }
        for window in windows { window.close() }
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        easyReader?.prepareForTermination()
    }

    // Opening the app again (Finder, Spotlight, the Dock icon) opens Settings: the way in without a menu bar icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        SettingsOpener.open()
        return false
    }

    // Files dropped on the Dock icon or opened with EasyReader in Finder (document types in Info.plist)
    func application(_ application: NSApplication, open urls: [URL]) {
        ReaderWindow.open(urls)
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        dockMenu
    }

    private func updateStatusItem() {
        let shown = Defaults[.appPresence] != .dock
        if shown, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)
            item.menu = statusMenu
            if let button = item.button { statusItemDropTarget.attach(to: button) }
            statusItem = item
        } else if !shown, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func playbackMenuItems() -> [NSMenuItem] {
        [
            {
                let menuItem = NSMenuItem()
                menuItem.action = #selector(toggleStartStopAction)
                menuItem.setShortcut(for: .toggleStartStop)
                return menuItem
            }(),
            {
                let menuItem = NSMenuItem()
                menuItem.action = #selector(togglePlayPauseAction)
                menuItem.setShortcut(for: .togglePlayPause)
                return menuItem
            }(),
            {
                let menuItem = NSMenuItem(title: "Skip Forward", action: #selector(skipForwardAction), keyEquivalent: "")
                menuItem.setShortcut(for: .skipForward)
                return menuItem
            }(),
            {
                let menuItem = NSMenuItem(title: "Skip Backward", action: #selector(skipBackwardAction), keyEquivalent: "")
                menuItem.setShortcut(for: .skipBackward)
                return menuItem
            }(),
        ]
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

    @objc func readSelectionInReaderWindowAction() {
        Log.app.debug("read selection in reader window")
        guard let app = NSWorkspace.shared.frontmostApplication, readSelectionInReaderWindow(of: app.processIdentifier) else {
            NSSound.beep()
            return
        }
    }

    /// Like Services' "Read with EasyReader" from any app: its selection (AX, else ⌘C) read in a reader window, titled after its window.
    func readSelectionInReaderWindow(of pid: pid_t) -> Bool {
        guard pid == getpid() || AXElement.isProcessTrusted(prompt: true) else { return false }
        let focused = try? AXElement.application(pid: pid).attribute(.focusedUIElement)
        guard let (text, _) = SelectedTextReadable.selectedText(in: pid, focused: focused) else { return false }
        let title = (try? focused?.attribute(.window)?.attribute(.title)).flatMap { $0.isEmpty ? nil : $0 }
        ReaderWindow.forNewContent().read(ReaderWindow.plainText(text), title: title ?? NSRunningApplication(processIdentifier: pid)?.localizedName ?? "Reader")
        return true
    }

    @objc func aboutAction() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }
}

extension AppDelegate: EasyReader.Delegate {
    func easyReader(_ reader: EasyReader, didChangeState state: EasyReader.State) {
        updateNowPlaying()
        statusMenu.update()
        ReaderWindow.updateToolbars()
    }

    // Skips and rate changes don't change the state
    func easyReaderDidStartUtterance(_ reader: EasyReader) {
        updateNowPlaying()
        ReaderWindow.updateToolbars()
    }

    private func updateNowPlaying() {
        nowPlayingManager.update(
            readable: easyReader.readable, state: easyReader.state, progress: easyReader.progress,
            hasFinished: easyReader.hasFinished)
    }
}

extension AppDelegate {
    enum Presence: String, Defaults.Serializable {
        case menuBar
        case dock
        case both
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
            case #selector(toggleStartStopAction): return PlaybackControl.startStop.apply(to: menuItem, for: easyReader)
            case #selector(togglePlayPauseAction): return PlaybackControl.playPause.apply(to: menuItem, for: easyReader)
            case #selector(skipForwardAction): return PlaybackControl.skipForward.apply(to: menuItem, for: easyReader)
            case #selector(skipBackwardAction): return PlaybackControl.skipBackward.apply(to: menuItem, for: easyReader)
            case nil: return false
            default: return true
        }
    }
}
