import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            SettingsTab("General", systemImage: "gear") {
                SettingsGeneralView()
            }
            SettingsTab("Speech", systemImage: "waveform") {
                SettingsSpeechView()
            }
            SettingsTab("Reading", systemImage: "book.fill") {
                SettingsReadingView()
            }
            SettingsTab("Pronunciations", systemImage: "character.bubble.fill") {
                SettingsPronunciationsView()
            }
        }
        .frame(width: 800, height: 540)
        .padding()
    }
}
