import Carbon.HIToolbox
import Cocoa

/// An app's selection via ⌘C, for apps that don't report it through AX. Restores the clipboard.
@MainActor
enum CopiedSelection {
    private static let ansiCKey: CGKeyCode = 8
    private static let lateCopyWindow: TimeInterval = 1

    // Not for our own process: we block its main thread while waiting.
    static func copy(from pid: pid_t, timeout: TimeInterval = 0.3) -> String? {
        guard pid != NSRunningApplication.current.processIdentifier else { return nil }
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        let count = pasteboard.changeCount
        postCopy(to: pid)
        let deadline = Date() + timeout
        var copied: String?
        // Some apps clear the clipboard before writing, so a change alone may not hold the text yet.
        while Date() < deadline {
            if pasteboard.changeCount != count, let text = text(on: pasteboard) {
                copied = text
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard pasteboard.changeCount != count else {
            restoreAfterLateCopy(since: count, saved)
            return nil
        }
        restore(saved)
        return copied
    }

    private static func postCopy(to pid: pid_t) {
        let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
        let key = source.flatMap { keyCode(for: "c", in: $0) } ?? ansiCKey
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)
            event?.flags = .maskCommand
            var c: UniChar = 0x63
            event?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
            event?.postToPid(pid)
        }
    }

    /// The key that types `character` with ⌘ held in `layout` (e.g. Dvorak's C isn't at ANSI C's position).
    static func keyCode(for character: Character, in layout: TISInputSource) -> CGKeyCode? {
        guard let property = TISGetInputSourceProperty(layout, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        return data.withUnsafeBytes { bytes -> CGKeyCode? in
            guard let keyboardLayout = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            let modifiers = UInt32((cmdKey >> 8) & 0xFF)
            for key in 0..<CGKeyCode(128) {
                var deadKeys: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    keyboardLayout, key, UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
                if status == noErr, String(utf16CodeUnits: chars, count: length) == String(character) { return key }
            }
            return nil
        }
    }

    private static func text(on pasteboard: NSPasteboard) -> String? {
        if let string = pasteboard.string(forType: .string) { return string }
        guard let rtf = pasteboard.data(forType: .rtf) else { return nil }
        return NSAttributedString(rtf: rtf, documentAttributes: nil)?.string
    }

    private static func restore(_ saved: [[(NSPasteboard.PasteboardType, Data)]]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(
            saved.map { pairs in
                let item = NSPasteboardItem()
                for (type, data) in pairs { item.setData(data, forType: type) }
                return item
            })
    }

    // A busy app may copy after we gave up; put the user's clipboard back if it does.
    private static func restoreAfterLateCopy(since count: Int, _ saved: [[(NSPasteboard.PasteboardType, Data)]]) {
        Task {
            let deadline = Date() + lateCopyWindow
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 20_000_000)
                if NSPasteboard.general.changeCount != count {
                    restore(saved)
                    return
                }
            }
        }
    }
}
