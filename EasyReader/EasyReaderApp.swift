import AVFoundation
import SwiftUI
import Defaults
import KeyboardShortcuts
import LaunchAtLogin

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
            CommandGroup(replacing: .help) {
                Button("EasyReader Help") { AppDelegate.showHelp() }
                    .keyboardShortcut("?")
            }
        }
    }
}

/// Opens the SwiftUI `Settings` scene from AppKit.
@MainActor
final class SettingsOpener: NSObject {
    private static let windowID = "com_apple_SwiftUI_Settings_window"

    /// Set by `SettingsView`: SwiftUI's window identifier differs on macOS 12.
    static weak var reportedWindow: NSWindow?

    static var window: NSWindow? {
        reportedWindow ?? NSApp.windows.first { $0.identifier?.rawValue == windowID }
    }

    static var name: String {
        if #available(macOS 13.0, *) { "Settings" } else { "Preferences" }
    }

    static var menuTitle: String { "\(name)…" }

    @objc static func open() {
        WindowPresenter.showAsRegular()
        // The `show…Window:` selectors below only log a warning on macOS 14+.
        if #available(macOS 14.0, *) {
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
        }
        Task { await WindowPresenter.activateAfterPolicyChange { window } }
        window?.makeKeyAndOrderFront(nil)
    }

    /// SwiftUI's Settings… item in the app menu (⌘,), present even while the menu bar isn't shown.
    private static func openWithMenuItem() {
        guard let menu = NSApp.mainMenu?.items.first?.submenu,
            let index = menu.items.firstIndex(where: { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command })
        else { return Log.settings.error("No Settings menu item") }
        menu.performActionForItem(at: index)
        window?.makeKeyAndOrderFront(nil)
    }

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
    private var settingsLoops: [Task<Void, Never>] = []

    // An agent app (`LSUIElement`) turned regular after launch isn't activated like one, so the guide's launch is regular from the start.
    func applicationWillFinishLaunching(_ notification: Notification) {
        if SetupGuide.isNeeded { NSApp.setActivationPolicy(.regular) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(SetupGuide.isNeeded ? .regular : WindowPresenter.restingPolicy)
        // A login item enabled on macOS 12 or earlier moves to SMAppService once the Mac runs 13+.
        if !UserDefaults.isUnderTest { LaunchAtLogin.migrateIfNeeded() }

        easyReader = EasyReader()
        easyReader.delegate = self
        nowPlayingManager = NowPlayingManager(reader: easyReader)
        ReaderWindow.reader = easyReader
        NSApp.servicesProvider = readerService
        NSUpdateDynamicServices()
        // Its first lookup takes ~450 ms.
        DispatchQueue.main.async { _ = AVSpeechSynthesisVoice.system }

        KeyboardShortcuts.onKeyDown(for: .toggleStartStop) { [weak self] in self?.toggleStartStopAction() }
        KeyboardShortcuts.onKeyDown(for: .togglePlayPause) { [weak self] in self?.playPauseShortcut() }
        for (name, direction) in [(KeyboardShortcuts.Name.skipForward, Selection.Direction.forward), (.skipBackward, .backward)] {
            KeyboardShortcuts.onKeyDown(for: name) { [weak self] in self?.skipShortcutDown(direction) }
            KeyboardShortcuts.onKeyUp(for: name) { [weak self] in self?.skipShortcutUp(direction) }
        }
        KeyboardShortcuts.onKeyDown(for: .readSelectionInReaderWindow) { [weak self] in self?.readSelectionInReaderWindowAction() }
        dockMenu.items = playbackMenuItems()
        statusMenu.items =
            playbackMenuItems() + [
                .separator(),
                NSMenuItem("Open…", action: #selector(ReaderWindow.openDocument), target: ReaderWindow.self, key: "o"),
                NSMenuItem("Open URL…", action: #selector(ReaderWindow.openWebPage), target: ReaderWindow.self, key: "l"),
                .separator(),
                NSMenuItem("About EasyReader", action: #selector(aboutAction)),
                NSMenuItem(SettingsOpener.menuTitle, action: #selector(SettingsOpener.open), target: SettingsOpener.self, key: ","),
                NSMenuItem("Quit", action: #selector(quitAction), key: "q"),
            ]
        updateStatusItem()

        KeyboardShortcuts.onKeyDown(for: .increaseRate) { [weak self] in
            guard let reader = self?.easyReader else { return }
            reader.changeRate(to: SpeechRate.stepped(reader.rate, by: 1))
            Log.app.debug("shortcut: increase rate → \(reader.rate)")
        }
        KeyboardShortcuts.onKeyDown(for: .decreaseRate) { [weak self] in
            guard let reader = self?.easyReader else { return }
            reader.changeRate(to: SpeechRate.stepped(reader.rate, by: -1))
            Log.app.debug("shortcut: decrease rate → \(reader.rate)")
        }
        KeyboardShortcuts.onKeyDown(for: .defaultRate) { [weak self] in
            guard let reader = self?.easyReader else { return }
            reader.changeRate(to: nil)
            Log.app.debug("shortcut: normal speed → \(reader.rate)")
        }

        settingsLoops = [
            Task { [weak self] in
                var settingRate = Defaults[.speechRate]
                for await _ in Defaults.updates([.speechVoice, .speechVolume, .speechRate, .speechPitch], initial: false) {
                    guard let self else { return }
                    Log.settings.debug("speech settings changed (state \(easyReader.state))")
                    if Defaults[.speechRate] != settingRate {
                        settingRate = Defaults[.speechRate]
                        easyReader.temporaryRate = nil
                    }
                    guard easyReader.state == .reading else { continue }
                    easyReader.play(from: .word)
                }
            },
            Task { [weak self] in
                for await value in Defaults.updates(.selectionUnit) {
                    guard let self else { return }
                    Log.settings.debug("selection unit: \(value)")
                    easyReader.textSelector = NLTextSelector(unit: value)
                }
            },
            Task { [weak self] in
                for await value in Defaults.updates(.nowPlayingCenterIntegration) {
                    guard let self else { return }
                    Log.settings.debug("Now Playing integration: \(value)")
                    nowPlayingManager.isEnabled = value
                }
            },
            Task { [weak self] in
                for await value in Defaults.updates(.appPresence, initial: false) {
                    guard let self else { return }
                    Log.settings.debug("app presence: \(value)")
                    updateStatusItem()
                    WindowPresenter.applyRestingPolicy()
                }
            },
            Task { [weak self] in
                for await value in Defaults.updates(.playWhenFinished, initial: false) {
                    guard let self else { return }
                    Log.settings.debug("play when finished: \(value)")
                    updateNowPlaying()
                }
            },
        ]

        SetupGuide.showIfNeeded()
    }

    /// Undoes `applicationDidFinishLaunching`'s observers and status item (tests launch several delegates). Removes every shortcut handler.
    func stopObserving() {
        for loop in settingsLoops { loop.cancel() }
        settingsLoops = []
        KeyboardShortcuts.removeAllHandlers()
        nowPlayingManager.isEnabled = false
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
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

    // Files dropped on the Dock icon or opened with EasyReader in Finder (document types in Info.plist).
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
            item.menu = statusMenu
            if let button = item.button { statusItemDropTarget.attach(to: button) }
            statusItem = item
            updateStatusItemImage()
        } else if !shown, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    // Generated by scripts/make-menu-bar-icons.swift (template images).
    private func updateStatusItemImage() {
        guard let button = statusItem?.button else { return }
        let name =
            switch easyReader.state {
                case .reading: "MenuBarIcon"
                case .paused: "MenuBarIconPaused"
                case .stopped: "MenuBarIconIdle"
            }
        let image = NSImage(named: name)
        image?.accessibilityDescription = "EasyReader"
        button.image = image
    }

    private func playbackMenuItems() -> [NSMenuItem] {
        [
            NSMenuItem(action: #selector(toggleStartStopAction), shortcut: .toggleStartStop),
            NSMenuItem(action: #selector(togglePlayPauseAction), shortcut: .togglePlayPause),
            NSMenuItem("Skip Forward", action: #selector(skipForwardAction), shortcut: .skipForward),
            NSMenuItem("Skip Backward", action: #selector(skipBackwardAction), shortcut: .skipBackward),
        ]
    }

    @objc func toggleStartStopAction() {
        Log.app.debug("toggle start/stop (state \(easyReader.state))")
        switch easyReader.state {
            case .stopped, .paused:
                NSSound.beep(unless: easyReader.start(reading: .frontmostApp))
            case .reading:
                NSSound.beep(unless: easyReader.stop())
        }
    }

    @objc func togglePlayPauseAction() {
        Log.app.debug("toggle play/pause (state \(easyReader.state))")
        NSSound.beep(unless: easyReader.togglePlayPause())
    }

    @objc func skipForwardAction() {
        Log.app.debug("skip forward")
        NSSound.beep(unless: easyReader.skip(.forward))
    }

    @objc func skipBackwardAction() {
        Log.app.debug("skip backward")
        NSSound.beep(unless: easyReader.skip(.backward))
    }

    /// Same as the media key, so "When finished, play key" applies too.
    private func playPauseShortcut() {
        Log.app.debug("shortcut: play/pause (state \(easyReader.state))")
        let hadFinished = easyReader.hasFinished
        // After finishing, playing again beeps itself where it should.
        if nowPlayingManager.perform(.togglePlayPause) != .success, !hadFinished { NSSound.beep() }
    }

    private var heldSkipShortcut: Selection.Direction?

    private func skipShortcutDown(_ direction: Selection.Direction) {
        guard heldSkipShortcut != direction else { return }
        Log.app.debug("shortcut: skip \(direction) (held: repeats)")
        heldSkipShortcut = direction
        NSSound.beep(unless: easyReader.beginRepeatingSkip(direction, firstRepeatAfter: NSEvent.keyRepeatDelay))
    }

    private func skipShortcutUp(_ direction: Selection.Direction) {
        guard heldSkipShortcut == direction else { return }
        heldSkipShortcut = nil
        easyReader.endRepeatingSkip()
    }

    @objc func readSelectionInReaderWindowAction() {
        Log.app.debug("read selection in reader window")
        guard let app = NSWorkspace.shared.frontmostApplication, ReaderWindow.readSelection(of: app.processIdentifier) else {
            NSSound.beep()
            return
        }
    }

    @objc func aboutAction() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    /// The README, in place of a Help Book.
    @objc static func showHelp() {
        NSWorkspace.shared.open(URL(string: "https://github.com/AlbatorLaho/EasyReader#readme")!)
    }
}

extension AppDelegate: EasyReader.Delegate {
    func easyReader(_ reader: EasyReader, didChangeState state: EasyReader.State) {
        updateNowPlaying()
        statusMenu.update()
        updateStatusItemImage()
        ReaderWindow.updateToolbars()
    }

    // Skips and rate changes don't change the state.
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

extension NSMenuItem {
    convenience init(_ title: String = "", action: Selector, target: AnyObject? = nil, key: String = "", shortcut: KeyboardShortcuts.Name? = nil) {
        self.init(title: title, action: action, keyEquivalent: key)
        self.target = target
        if let shortcut { setShortcut(for: shortcut) }
    }
}

extension NSSound {
    static func beep(unless succeeded: Bool) {
        if !succeeded { beep() }
    }
}
