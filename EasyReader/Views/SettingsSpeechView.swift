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
            .mapValues { voices in voices.sorted { $0.name < $1.name } }
            .sorted { $0.key < $1.key }
            .map { language, voices in
                (language: Locale.current.localizedString(forIdentifier: language) ?? language, voices: voices)
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            GroupBox {
                Form {
                    SliderControls(value: $speechVolume, in: 0...1, step: 0.1, max: 1, format: .percent) {
                        Image(systemName: speechVolume == 0 ? "speaker.fill" : "speaker.wave.\(1 + Int(speechVolume * 2)).fill")
                            .frame(width: 24, alignment: .leading)
                        Text("Volume:")
                    } minimumValueLabel: {
                        Text("0%")
                    } maximumValueLabel: {
                        Text("100%")
                    }

                    SliderControls(
                        value: Binding(
                            get: { SpeechRate.multiplier(forRate: speechRate) },
                            set: { newValue in
                                speechRate = SpeechRate.clamped(SpeechRate.rate(forMultiplier: newValue))
                            }
                        ), in: SpeechRate.minimumMultiplier...SpeechRate.maximumMultiplier, step: 0.25, max: 4, format: .percent
                    ) {
                        Text("Rate:")
                    } minimumValueLabel: {
                        Text("½")
                    } maximumValueLabel: {
                        Text("4×")
                    }

                    SliderControls(value: $speechPitch, in: 0.5...2, step: 0.1, min: 0.5, max: 2, format: .percent) {
                        Text("Pitch:")
                    } minimumValueLabel: {
                        Text("½")
                    } maximumValueLabel: {
                        Text("2×")
                    }
                }
            } label: {
                Picker("Voice:", systemImage: "mic.fill", selection: $speechVoice) {
                    if let speechSystemVoice = Self.speechSystemVoice {
                        Text("System Voice (\(speechSystemVoice.name), \(speechSystemVoice.language))").tag(nil as AVSpeechSynthesisVoice?)
                    } else {
                        Text("System Voice (*unknown*)").tag(nil as AVSpeechSynthesisVoice?)
                    }
                    Divider()
                    ForEach(Self.speechVoices, id: \.language) { language, voices in
                        Section {
                            ForEach(voices, id: \.identifier) { voice in
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
                    } minimumValueLabel: {
                        Text("0s")
                    } maximumValueLabel: {
                        Text("1s")
                    }

                    SliderControls(value: $speechDelayAfter, in: 0...1, step: 0.1) {
                        Text("Delay After:")
                    } minimumValueLabel: {
                        Text("0s")
                    } maximumValueLabel: {
                        Text("1s")
                    }
                }
            } label: {
                Label("Behavior", systemImage: "text.alignleft")
            }

            Spacer()

            HStack {
                Spacer()
                ResetDefaultsButton(
                    for: "speech",
                    keys: [
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
            • System Voice - the default voice for your language
            • changing the voice or rate while reading restarts from the current word
            • Stop Boundary - whether pausing/stopping happens immediately, or after the current word
            • Delay Before - adds a delay before reading a selection
            • Delay After - adds a delay after reading a selection

            Caveats/Bugs:
            • voice pitch does not behave the same, and may appear to have no effect, depending on which voice is used
            """
        }
    }
}
