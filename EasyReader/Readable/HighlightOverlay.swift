//
//  HighlightOverlay.swift
//  EasyReader
//

import Cocoa

/// Highlights the unit being read in apps that don't let AX clients set their selection (Chromium page text): a
/// click-through window drawn over the text.
///
/// While shown, it re-fetches the rects a few times a second (`rects` returns nil to hide), so it follows scrolling and
/// hides while its app isn't frontmost.
@MainActor
final class HighlightOverlay {
    private var window: NSWindow?
    private var refresh: Task<Void, Never>?
    private var rects: (() -> [CGRect]?)?
    private var shown: [CGRect] = []

    /// Highlights the rects (screen coordinates, top-left origin as in AX) `rects` returns, until `hide`.
    func show(_ rects: @escaping () -> [CGRect]?) {
        self.rects = rects
        update()
        guard refresh == nil else { return }
        refresh = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, !Task.isCancelled else { return }
                self.update()
            }
        }
    }

    func hide() {
        refresh?.cancel()
        refresh = nil
        rects = nil
        shown = []
        window?.orderOut(nil)
    }

    var isVisible: Bool { window?.isVisible == true }

    private func update() {
        guard let rects = rects?(), !rects.isEmpty, let screen = NSScreen.screens.first else {
            shown = []
            window?.orderOut(nil)
            return
        }
        guard rects != shown || !isVisible else { return }
        shown = rects
        // AX rects have their origin at the top left of the main screen; AppKit at its bottom left.
        let flipped = rects.map { CGRect(x: $0.minX, y: screen.frame.maxY - $0.maxY, width: $0.width, height: $0.height) }
        let frame = flipped.reduce(flipped[0]) { $0.union($1) }.insetBy(dx: -2, dy: -2)
        let window = self.window ?? makeWindow()
        window.setFrame(frame, display: false)
        let view = window.contentView as! HighlightView
        view.rects = flipped.map { $0.offsetBy(dx: -frame.minX, dy: -frame.minY) }
        view.needsDisplay = true
        window.orderFrontRegardless()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.contentView = HighlightView()
        self.window = window
        return window
    }
}

private final class HighlightView: NSView {
    var rects: [CGRect] = []

    override func draw(_ dirtyRect: NSRect) {
        NSColor.findHighlightColor.withAlphaComponent(0.35).setFill()
        for rect in rects {
            NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: 0), xRadius: 3, yRadius: 3).fill()
        }
    }
}
