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
    @Default(.scrollSelectionIntoView) private var scrollSelectionIntoView
    @Default(.scrollPadding) private var scrollPadding
    @Default(.scrollSmooth) private var scrollSmooth
    @Default(.scrollDuration) private var scrollDuration
    @Default(.scrollUpdateRate) private var scrollUpdateRate

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            GroupBox {
                Form {
                    Picker("Unit:", selection: $selectionUnit) {
                        Text("Sentence").tag(Selection.Unit.sentence)
                        Text("Paragraph").tag(Selection.Unit.paragraph)
                    }
                }
            } label: {
                Label("Selecting", systemImage: "doc.text.magnifyingglass")
            }

            GroupBox {
                Form {
                    SliderControls(value: $scrollPadding, in: 0...64, step: 8) {
                        Text("Padding:")
                    } minimumValueLabel: { Text("0px") } maximumValueLabel: { Text("64px") }

                    GroupBox {
                        Form {
                            SliderControls(value: $scrollDuration, in: 0...1, step: 0.1) {
                                Text("Duration:")
                            } minimumValueLabel: { Text("0s") } maximumValueLabel: { Text("1s") }

                            SliderControls(value: $scrollUpdateRate, in: 30...60, step: 5, format: .none) {
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
            \t• Duration - how long (in seconds) smooth scrolling takes to finish (zero results in immediate scrolling)
            \t• Increments - how many times per second, smooth scrolling will be updated (zero results in not updating at all)
            """
        }
    }
}
