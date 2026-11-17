import AppKit

/// The playback controls shared by the status/Dock menus and the reader window's toolbar.
@MainActor
enum PlaybackControl: String, CaseIterable {
    case startStop, playPause, skipBackward, skipForward

    struct Appearance {
        let title: String
        /// SF Symbol names, the first one available used.
        let symbols: [String]
        let isEnabled: Bool

        init(title: String, symbol: String..., isEnabled: Bool) {
            self.title = title
            self.symbols = symbol
            self.isEnabled = isEnabled
        }

        var image: NSImage? {
            symbols.lazy.compactMap { NSImage(systemSymbolName: $0, accessibilityDescription: title) }.first
        }
    }

    // Speaker bubble: `.left` on 13, none on 11–12.
    func appearance(for reader: EasyReader?) -> Appearance {
        let state = reader?.state ?? .stopped
        return switch self {
            case .startStop:
                state == .reading
                    ? Appearance(title: "Stop", symbol: "stop.fill", isEnabled: true)
                    : Appearance(
                        title: "Start", symbol: "speaker.wave.2.bubble.fill", "speaker.wave.2.bubble.left.fill", "text.bubble.fill", isEnabled: reader != nil)
            case .playPause:
                state == .paused
                    ? Appearance(title: "Resume", symbol: "play.fill", isEnabled: true)
                    : Appearance(title: "Pause", symbol: "pause.fill", isEnabled: state != .stopped)
            case .skipBackward: Appearance(title: "Skip Backward", symbol: "gobackward", isEnabled: state != .stopped)
            case .skipForward: Appearance(title: "Skip Forward", symbol: "goforward", isEnabled: state != .stopped && reader?.canSkipForward == true)
        }
    }

    /// Sets the item's title and image; returns whether it's enabled (for `validateMenuItem`).
    func apply(to menuItem: NSMenuItem, for reader: EasyReader?) -> Bool {
        let appearance = appearance(for: reader)
        menuItem.title = appearance.title
        menuItem.image = appearance.image
        return appearance.isEnabled
    }
}
