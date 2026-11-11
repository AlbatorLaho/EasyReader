//
//  SettingsGeneralView.swift
//  EasyReader
//
//  Created by Ewalk on 2025-01-31.
//

import SwiftUI
import Defaults
import KeyboardShortcuts

struct SettingsGeneralView: View {
    @Default(.nowPlayingCenterIntegration) private var nowPlayingCenterIntegration

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            GroupBox {
                Form {
                    KeyboardShortcuts.Recorder("Start/Stop:", name: .toggleStartStop)
                    KeyboardShortcuts.Recorder("Increase Rate:", name: .increaseRate)
                    KeyboardShortcuts.Recorder("Decrease Rate:", name: .decreaseRate)
                    KeyboardShortcuts.Recorder("Default Rate:", name: .defaultRate)

                    GroupBox {
                        Form {
                            KeyboardShortcuts.Recorder("Play/Pause:", name: .togglePlayPause)
                            KeyboardShortcuts.Recorder("Skip Forward:", name: .skipForward)
                            KeyboardShortcuts.Recorder("Skip Backward:", name: .skipBackward)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("Not needed with \"Now Playing Center\"")
                            InfoButton(
                                "Media keys already play/pause and skip with Now Playing Center.",
                                title: "Media Keys Cover These",
                                "When \"Now Playing Center\" integration is enabled (below), the keyboard's media keys (▶︎❙❙, ◀︎◀︎, ▶︎▶︎) play/pause and skip backward/forward, so these shortcuts are optional."
                            )
                        }
                    }
                    .padding(.top)
                }
            } label: {
                Label("Global Shortcuts", systemImage: "command")
            }

            HStack(spacing: 4) {
                Toggle("\"Now Playing Center\" integration", systemImage: "play.circle", isOn: $nowPlayingCenterIntegration)
                InfoButton(
                    "Control reading with the media keys and see it in Now Playing.",
                    title: "Now Playing Center",
                    "Lets the keyboard's media keys (and headphone buttons) play/pause and skip while EasyReader reads.",
                    "Also shows what's being read (the app and window) in Control Center's Now Playing, like music."
                )
            }
//            Toggle("\"Now Playing Center\" integration", systemImage: "play.circle", isOn: $nowPlayingCenterIntegration)
//            GroupBox {
//                Form {
//                }
//                .disabled(!nowPlayingCenterIntegration)
//            } label: {
//                Toggle("\"Now Playing Center\" integration", systemImage: "play.circle", isOn: $nowPlayingCenterIntegration)
//            }

            Spacer()

            ChromiumSelectionInfo()

            HStack {
                AccessibilityPermissionButton()
                Spacer()
//                ResetDefaultsButton(for: "general", keys: [
//                    .nowPlayingCenterIntegration,
//                ])
//                ResetDefaultsButton(for: "general") {
//                    KeyboardShortcuts.resetAll()
//                    Defaults.reset([
//                        .nowPlayingCenterIntegration,
//                    ])
//                }
                ResetDefaultsButton(for: "all") {
                    KeyboardShortcuts.resetAll()
                    Defaults.removeAll()
                } label: {
                    Label("Reset all settings...", systemImage: "exclamationmark.triangle.fill")
                }
            }
        }

        TextPlayground("General Playground") {
            """
            Welcome to \(NSRunningApplication.current.localizedName!)!
            A utility to assist the built-in MacOS screen reader.
            
            Key features:
            • selects text as it's reading
            • modify selection while reading, to change what will be read next
            • can integrate with the "Now Playing Center" and media keys
            • can scroll the selection into view while reading
            
            Behavior:
            • reading is modified by what the current selection is, i.e. reading continues from the end of the selection
            • while reading, if you make no selection, reading will stop
            • will attempt to start reading from the currently focused UI element (currently only TextArea is supported)
            • starts reading from your current selection, or will make a selection if there is none
            
            Caveats/Bugs:
            • some UI elements don't look/behave correctly prior to MacOS 13
            • reading sometimes hangs, and (usually) requires restarting the app to fix
            """
        }
    }
}

/// Trust takes effect immediately (no relaunch needed); re-check when the system's Accessibility list
/// changes and when the app becomes active, since the view otherwise never redraws.
private struct AccessibilityPermissionButton: View {
    @State private var isTrusted = AXElement.isProcessTrusted()
    private static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    var body: some View {
        Button {
            if isTrusted {
                // Undocumented URL (System Preferences' pane ID, still mapped by System Settings on macOS 13+);
                // fall back to opening System Settings itself.
                if !NSWorkspace.shared.open(Self.settingsURL) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:")!)
                }
            } else {
                // The system prompt also adds the app to the Accessibility list.
                isTrusted = AXElement.isProcessTrusted(prompt: true)
            }
        } label: {
            if #available(macOS 12.0, *) {
                Image(systemName: "circle.fill")
                    .imageScale(.small)
                    .foregroundStyle(isTrusted ? .green : .red)
            } else {
                Image(systemName: "circle.fill")
                    .imageScale(.small)
                    .foregroundColor(isTrusted ? .green : .red)
            }
            Text(isTrusted ? "Accessibility Settings…" : "Request Accessibility Permission…")
        }
        .onReceive(DistributedNotificationCenter.default().publisher(for: Notification.Name("com.apple.accessibility.api"))) { _ in
            // Posted as the change is being applied; the trust check can lag briefly.
            Task {
                try? await Task.sleep(seconds: 0.5)
                refresh()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    private func refresh() {
        isTrusted = AXElement.isProcessTrusted()
    }
}
