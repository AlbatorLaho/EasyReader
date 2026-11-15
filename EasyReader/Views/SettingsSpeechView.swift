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
                        ), in: SpeechRate.minimumMultiplier...SpeechRate.maximumMultiplier, step: SpeechRate.step, max: 4, format: .percent
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
                HStack {
                    Label("Voice:", systemImage: "mic.fill")
                    VoicePicker(selection: $speechVoice).fixedSize()
                }
            }

            GroupBox {
                Form {
                    Picker("Stop Boundary:", selection: $speechStopBoundary) {
                        Text("Immediate").tag(EasyReader.StopBoundary.immediate)
                        Text("Word").tag(EasyReader.StopBoundary.word)
                        Text("Selection").tag(EasyReader.StopBoundary.selection)
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

// A SwiftUI `Picker` with this many items renders slowly (~0.6 s).
private struct VoicePicker: NSViewRepresentable {
    @Binding var selection: AVSpeechSynthesisVoice?

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.choose(_:))
        let menu = NSMenu()
        let systemVoice = AVSpeechSynthesisVoice.system
        menu.addItem(withTitle: systemVoice.map { "System Voice (\($0.name), \($0.language))" } ?? "System Voice", action: nil, keyEquivalent: "")
        for (language, voices) in Self.languages() {
            menu.addItem(.separator())
            if #available(macOS 14.0, *) {
                menu.addItem(.sectionHeader(title: language))
            } else {
                let header = NSMenuItem(title: language, action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
            }
            for voice in voices {
                let item = NSMenuItem(title: voice.name, action: nil, keyEquivalent: "")
                item.representedObject = voice.identifier
                menu.addItem(item)
            }
        }
        button.menu = menu
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        let index = selection.map { button.indexOfItem(withRepresentedObject: $0.identifier) } ?? 0
        button.selectItem(at: max(index, 0))
    }

    private static func languages() -> [(language: String, voices: [AVSpeechSynthesisVoice])] {
        Dictionary(grouping: AVSpeechSynthesisVoice.speechVoices(), by: \.language)
            .mapValues { voices in voices.sorted { $0.name < $1.name } }
            .sorted { $0.key < $1.key }
            .map { language, voices in
                (language: Locale.current.localizedString(forIdentifier: language) ?? language, voices: voices)
            }
    }

    @MainActor final class Coordinator: NSObject {
        var selection: Binding<AVSpeechSynthesisVoice?>

        init(selection: Binding<AVSpeechSynthesisVoice?>) {
            self.selection = selection
        }

        @objc func choose(_ sender: NSPopUpButton) {
            selection.wrappedValue = (sender.selectedItem?.representedObject as? String).flatMap(AVSpeechSynthesisVoice.init(identifier:))
        }
    }
}
