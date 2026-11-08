//
//  SettingsReadingView.swift
//  EasyReader
//
//  Created by Ewalk on 2025-01-31.
//

import SwiftUI
import Defaults

struct SettingsReadingView: View {
//    TODO: rename these to properly reflect their display names
    @Default(.selectionUnit) private var selectionUnit
    @Default(.resumeUnit) private var resumeUnit
    @Default(.scrollSelectionIntoView) private var scrollSelectionIntoView
    @Default(.scrollPadding) private var scrollPadding
    @Default(.scrollSmooth) private var scrollSmooth
    @Default(.scrollDuration) private var scrollDuration
    @Default(.scrollUpdateRate) private var scrollUpdateRate

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            GroupBox {
                Form {
                    Picker("Selection Unit:", selection: $selectionUnit) {
                        Text("Sentence").tag(Selection.Unit.sentence)
                        Text("Paragraph").tag(Selection.Unit.paragraph)
                    }

                    Picker("Resume From:", selection: $resumeUnit) {
                        Text("Word").tag(EasyReader.ResumeUnit.word)
                        Text("Selection").tag(EasyReader.ResumeUnit.selection)
                    }
                }
            } label: {
//                Label("Selecting", systemImage: "doc.text.magnifyingglass")
                Label("Reading", systemImage: "doc.plaintext")
            }

            ChromiumSelectionInfo()

            GroupBox {
                Form {
                    SliderControls(value: $scrollPadding, in: 0...64, step: 8) {
                        Text("Padding:")
                    } minimumValueLabel: { Text("0px") } maximumValueLabel: { Text("64px") }

                    GroupBox {
                        Form {
                            SliderControls(value: $scrollDuration, in: 0.1...1, step: 0.1) {
                                Text("Duration:")
                            } minimumValueLabel: { Text("0.1s") } maximumValueLabel: { Text("1s") }

                            SliderControls(value: $scrollUpdateRate, in: 30...60, step: 5, min: 1, format: .none) {
                                Text("Increments:")
                            } minimumValueLabel: { Text("30/s") } maximumValueLabel: { Text("60/s") }
                        }
                        .disabled(!scrollSmooth)
                    } label: {
//                        Toggle("Smooth Scrolling", systemImage: "arrow.up.arrow.down", isOn: $scrollSmooth)
                        Toggle("Smooth Scrolling", systemImage: "point.fill.topleft.down.curvedto.point.fill.bottomright.up", isOn: $scrollSmooth)
                    }
                    .padding(.top)
                }
                .disabled(!scrollSelectionIntoView)
            } label: {
//                Toggle("Auto Scrolling", systemImage: "note.text", isOn: $scrollSelectionIntoView)
                Toggle("Auto Scrolling", systemImage: "arrow.up.arrow.down", isOn: $scrollSelectionIntoView)
//                Toggle("Auto Scrolling", systemImage: "arrow.up.and.down.text.horizontal", isOn: $scrollSelectionIntoView)
            }

            Spacer()

            HStack {
                Spacer()
                ResetDefaultsButton(for: "reading", keys: [
                    .selectionUnit,
                    .resumeUnit,
                    .scrollSelectionIntoView,
                    .scrollPadding,
                    .scrollSmooth,
                    .scrollDuration,
                    .scrollUpdateRate,
                ])
            }
        }

        TextPlayground("Reading Playground") {
            """
            Text for testing reading
            
            Selecting:
            • Unit - how to select the next/previous piece of text
            
            Auto Scrolling:
            • Padding - how many pixels to pad the scrolling from the top and bottom of the view
            • Smooth Scrolling - scroll smoothly, instead of immediately
            \t• Duration - how long (in seconds) smooth scrolling takes to finish
            \t• Increments - how many times per second, smooth scrolling will be updated
            """
        }
    }
}

/// Chromium browsers only let EasyReader select page text with an experimental flag (else it highlights with an overlay).
private struct ChromiumSelectionInfo: View {
    static let flag = "chrome://flags/#enable-accessibility-text-operation"

    var body: some View {
        HStack {
            Label("Chrome, Brave, Edge: enable \"Text editing through accessibility APIs\"", systemImage: "info.circle")
                .help(
                    """
                    Chromium browsers only let EasyReader select web page text after enabling the flag \
                    "Enable text editing through accessibility APIs" (paste \(Self.flag) into the address bar, \
                    set it to Enabled, and relaunch the browser). Without it, EasyReader highlights what it reads \
                    with an overlay instead.
                    """)
            Spacer()
            Button("Copy Flag") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Self.flag, forType: .string)
            }
            .help("Copies \(Self.flag): paste it into the browser's address bar")
        }
    }
}
