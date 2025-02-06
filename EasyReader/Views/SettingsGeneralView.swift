//
//  SettingsGeneralView.swift
//  EasyReader
//
//  Created by Ewalk on 2025-01-31.
//

import SwiftUI
import Defaults
import KeyboardShortcuts
import AXSwift

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
                        Label("Not needed with \"Now Playing Center\"", systemImage: "info.circle")
                            .help("When \"Now Playing Center\" is enabled, you can use the media keys to play/pause and skip backwards/forwards")
                    }
                    .padding(.top)
                }
            } label: {
                Label("Global Shortcuts", systemImage: "command")
            }

            HStack {
                Toggle("\"Now Playing Center\" integration", systemImage: "play.circle", isOn: $nowPlayingCenterIntegration)
                Image(systemName: "info.circle")
            }
            .help("When enabled, allows use of media keys to control reading, and shows info about the current application and window that's being read from")
//            Toggle("\"Now Playing Center\" integration", systemImage: "play.circle", isOn: $nowPlayingCenterIntegration)
//            GroupBox {
//                Form {
//                }
//                .disabled(!nowPlayingCenterIntegration)
//            } label: {
//                Toggle("\"Now Playing Center\" integration", systemImage: "play.circle", isOn: $nowPlayingCenterIntegration)
//            }

            Spacer()

            HStack {
                Button {
                    _ = UIElement.isProcessTrusted(withPrompt: true)
                } label: {
//                    FIXME: color doesn't update reliably
                    if #available(macOS 12.0, *) {
                        Image(systemName: "circle.fill")
                            .imageScale(.small)
                            .foregroundStyle(UIElement.isProcessTrusted() ? .green : .red)
                    } else {
                        Image(systemName: "circle.fill")
                            .imageScale(.small)
                            .foregroundColor(UIElement.isProcessTrusted() ? .green : .red)
                    }
                    Text("Request Accessibility Permission")
                }
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
