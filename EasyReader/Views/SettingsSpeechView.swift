//
//  SettingsSpeechView.swift
//  EasyReader
//
//  Created by Ewalk on 2025-01-31.
//

import SwiftUI
import Defaults
import AVKit

struct SettingsSpeechView: View {
    @Default(.speechVoice) private var speechVoice
    @Default(.speechVolume) private var speechVolume
    @Default(.speechRate) private var speechRate
    @Default(.speechPitch) private var speechPitch
    @Default(.speechStopBoundary) private var speechStopBoundary
    @Default(.speechDelayBefore) private var speechDelayBefore
    @Default(.speechDelayAfter) private var speechDelayAfter

    static private var speechSystemVoice: AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
    }

    static private var speechVoices: [(language: String, voices: [AVSpeechSynthesisVoice])] {
        Dictionary(grouping: AVSpeechSynthesisVoice.speechVoices(), by: \.language)
            .mapValues({ voices in
                voices.sorted(by: { $0.name < $1.name })
            })
            .sorted(by: { $0.key < $1.key })
            .map({ key, value in
//                Locale(identifier: AVSpeechSynthesisVoice.currentLanguageCode())
                (language: Locale.current.localizedString(forIdentifier: key) ?? key, voices: value)
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            GroupBox {
                Form {
//                    Slider(value: $speechVolume, in: 0...1, step: 0.1) {
////                        Label("Volume:", systemImage: speechVolume == 0 ? "speaker.fill" : "speaker.wave.\(1 + Int(speechVolume * 2)).fill")
//                        Image(systemName: speechVolume == 0 ? "speaker.fill" : "speaker.wave.\(1 + Int(speechVolume * 2)).fill")
//                            .frame(width: 24, alignment: .leading)
//                        Text("Volume:")
//                    } minimumValueLabel: { Text("0%") } maximumValueLabel: { Text("100%") }

//                    SliderControls(value: $speechRate, in: 0.25...0.75, step: 0.05, max: 1) {
//                        Text("Rate:")
//                    } minimumValueLabel: { Text("½") } maximumValueLabel: { Text("2×") }
//                    SliderControls(value: $speechPitch, in: 0.5...1.5, step: 0.1) {
//                        Text("Pitch:")
//                    } minimumValueLabel: { Text("½") } maximumValueLabel: { Text("2×") }

                    SliderControls(value: $speechVolume, in: 0...1, step: 0.1, max: 1, format: .percent) {
                        Image(systemName: speechVolume == 0 ? "speaker.fill" : "speaker.wave.\(1 + Int(speechVolume * 2)).fill")
                            .frame(width: 24, alignment: .leading)
                        Text("Volume:")
                    } minimumValueLabel: { Text("0%") } maximumValueLabel: { Text("100%") }

                    SliderControls(value: Binding(
                        get: { speechRate * 2 },
                        set: { newValue in speechRate = newValue / 2 }
                    ), in: 0.5...2, step: 0.1, max: 2, format: .percent) {
                        Text("Rate:")
                    } minimumValueLabel: { Text("½") } maximumValueLabel: { Text("2×") }

                    SliderControls(value: $speechPitch, in: 0.5...2, step: 0.1, min: 0.5, max: 2, format: .percent) {
                        Text("Pitch:")
                    } minimumValueLabel: { Text("½") } maximumValueLabel: { Text("2×") }
                }
            } label: {
                Picker("Voice:", systemImage: "mic.fill", selection: $speechVoice) {
//                    Text("System Voice (\(Self.speechSystemVoice?.name ?? "*unknown*"))").tag(nil as AVSpeechSynthesisVoice?)
                    if let speechSystemVoice = Self.speechSystemVoice {
                        Text("System Voice (\(speechSystemVoice.name), \(speechSystemVoice.language))").tag(nil as AVSpeechSynthesisVoice?)
                    } else {
                        Text("System Voice (*unknown*)").tag(nil as AVSpeechSynthesisVoice?)
                    }
                    Divider()
                    ForEach(Self.speechVoices, id: \.language) { language, voices in
                        Section() {
                            ForEach(voices, id: \.identifier) { voice in
//                                Text(voice.name).tag(voice)
                                Text(voice.name).tag(voice as AVSpeechSynthesisVoice?)
                            }
                        } header: {
                            Text(language)
                        }
                    }
                }
            }

            GroupBox {
                Form {
                    Picker("Stop Boundary:", selection: $speechStopBoundary) {
                        Text("Immediate").tag(AVSpeechBoundary.immediate)
                        Text("Word").tag(AVSpeechBoundary.word)
                    }

                    SliderControls(value: $speechDelayBefore, in: 0...1, step: 0.1) {
                        Text("Delay Before:")
                    } minimumValueLabel: { Text("0s") } maximumValueLabel: { Text("1s") }

                    SliderControls(value: $speechDelayAfter, in: 0...1, step: 0.1) {
                        Text("Delay After:")
                    } minimumValueLabel: { Text("0s") } maximumValueLabel: { Text("1s") }
                }
            } label: {
//                Label("Behavior", systemImage: "doc.text")
//                Label("Behavior", systemImage: "doc.plaintext")
                Label("Behavior", systemImage: "text.alignleft")
            }

            Spacer()

            HStack {
                Spacer()
                ResetDefaultsButton(for: "speech", keys: [
                    .speechVoice,
                    .speechVolume,
                    .speechRate,
                    .speechPitch,
                    .speechStopBoundary,
                    .speechDelayBefore,
                    .speechDelayAfter,
                ])
            }
        }

        TextPlayground("Speech Playground") {
            """
            Text for testing speech
            
            Explanations:
            • Stop Boundary - affects when pausing/stopping is done
            • Delay Before - adds a delay before reading a selection
            • Delay After - adds a delay after reading a selection
            
            Caveats/Bugs:
            • voice pitch does not behave the same, and may appear to have no affect, depending on which voice is used
            """
        }
    }
}
