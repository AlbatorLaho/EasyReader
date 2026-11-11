//
//  ChromiumSelectionInfo.swift
//  EasyReader
//

import AppKit
import SwiftUI

/// Chromium browsers only let EasyReader select page text with an experimental flag (else it highlights with an overlay).
struct ChromiumSelectionInfo: View {
    static let flag = "chrome://flags/#enable-accessibility-text-operation"

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("Chromium browsers need this flag enabled for text selection:")
                InfoButton("Lets EasyReader select web page text in Chromium browsers (Chrome, Brave, Edge…).") {
                    Text("Selecting Text in Chromium Browsers").font(.headline)
                    Text(
                        "Chrome, Brave, Edge and other Chromium browsers only let EasyReader select web page text after turning on an experimental flag. Without it, EasyReader highlights what it reads with an overlay instead."
                    )
                    Text("1. Click the flag to copy it, then paste it into the browser's address bar.")
                    Text("2. Set \"Enable text editing through accessibility APIs\" to Enabled.")
                    Text("3. Relaunch the browser.")
                }
            }
            // One line with its ⓘ, never wrapped (the column widens instead).
            .fixedSize()
            CopyableFlag(flag: Self.flag)
        }
    }
}

/// The flag, link-styled: a click copies it (no app opens `chrome://` links), confirmed by "Copied".
private struct CopyableFlag: View {
    let flag: String
    @State private var isHovered = false
    @State private var copiedAt: Date?

    var body: some View {
        HStack(spacing: 6) {
            Button(action: copy) {
                Text(flag)
                    .foregroundColor(.accentColor)
                    .underline(isHovered)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .onDisappear {
                if isHovered { NSCursor.pop() }
                isHovered = false
            }
            .help("Click to copy, then paste it into the browser's address bar")
            if copiedAt != nil {
                Text("Copied").foregroundColor(.secondary)
            }
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(flag, forType: .string)
        let now = Date()
        copiedAt = now
        Task { @MainActor in
            try? await Task.sleep(seconds: 2)
            if copiedAt == now { copiedAt = nil }
        }
    }
}
