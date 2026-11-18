import SwiftUI
import AppKit
import AVFoundation

// A SwiftUI `Picker` with this many items renders slowly (~0.6 s).
struct VoicePicker: NSViewRepresentable {
    @Binding var selection: AVSpeechSynthesisVoice?

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.choose(_:))
        let menu = NSMenu()
        let systemVoice = AVSpeechSynthesisVoice.system
        menu.addItem(withTitle: systemVoice.map { "System Voice (\($0.name), \($0.language))" } ?? "System Voice", action: nil, keyEquivalent: "")
        for (language, voices) in Self.languages(of: AVSpeechSynthesisVoice.speechVoices()) {
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

    /// Sorted by the shown (localized) language name.
    nonisolated static func languages(
        of voices: [AVSpeechSynthesisVoice], locale: Locale = .current
    ) -> [(language: String, voices: [AVSpeechSynthesisVoice])] {
        Dictionary(grouping: voices, by: \.language)
            .map { language, voices in
                (language: locale.localizedString(forIdentifier: language) ?? language, voices: voices.sorted { $0.name < $1.name })
            }
            .sorted { $0.language.localizedStandardCompare($1.language) == .orderedAscending }
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
