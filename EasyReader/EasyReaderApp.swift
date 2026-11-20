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
    private nonisolated static let windowIDs: Set = [windowID, ReaderWindow.windowID, SetupGuide.windowID]

    private static var hasOpenWindow: Bool {
        NSApp.windows.contains { $0.isVisible && windowIDs.contains($0.identifier?.rawValue ?? "") }
    }

    private static var closeObserver: NSObjectProtocol?

    static var name: String {
        if #available(macOS 13.0, *) { "Settings" } else { "Preferences" }
    }

    static var menuTitle: String { "\(name)…" }

    @objc static func open() {
        showAsRegular()
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
            Task { await activateAfterPolicyChange { window } }
        }
        window?.makeKeyAndOrderFront(nil)
    }

    /// Shows one of the app's other windows the way `open` shows Settings; `then` runs once it's key (or after 1 s).
    static func present(_ window: NSWindow, then action: (@MainActor () -> Void)? = nil) {
        showAsRegular()
        window.makeKeyAndOrderFront(nil)
        Task {
            await activateAfterPolicyChange { window }
            for _ in 0..<18 where !window.isKeyWindow {
                try? await Task.sleep(seconds: 0.05)
            }
            action?()
        }
    }

    // A Dock icon while open, so the window can be found with ⌘-Tab and the Dock
    private static func showAsRegular() {
        NSApp.setActivationPolicy(.regular)
        observeClose()
        // Closing the window hid an accessory app, and a hidden app's windows stay hidden.
        NSApp.unhide(nil)
    }

    // Activated before the policy change lands, the app isn't put first in ⌘-Tab.
    private static func activateAfterPolicyChange(_ window: () -> NSWindow?) async {
        try? await Task.sleep(seconds: 0.1)
        NSApp.activate(ignoringOtherApps: true)
        window()?.makeKeyAndOrderFront(nil)
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
    private var settingsLoops: [Task<Void, Never>] = []

    // An agent app (`LSUIElement`) turned regular after launch isn't activated like one, so the guide's launch is regular from the start.
    func applicationWillFinishLaunching(_ notification: Notification) {
        if SetupGuide.isNeeded { NSApp.setActivationPolicy(.regular) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(SetupGuide.isNeeded ? .regular : SettingsOpener.restingPolicy)
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

        settingsLoops = [
            Task { [weak self] in
                for await _ in Defaults.updates([.speechVoice, .speechVolume, .speechRate, .speechPitch], initial: false) {
                    guard let self else { return }
                    Log.settings.debug("speech settings changed (state \(easyReader.state))")
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
                    SettingsOpener.applyRestingPolicy()
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

    /// Same as the media key, so "When finished, Play key" applies too.
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
}

extension AppDelegate: EasyReader.Delegate {
    func easyReader(_ reader: EasyReader, didChangeState state: EasyReader.State) {
        updateNowPlaying()
        statusMenu.update()
        updateStatusItemImage()
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
