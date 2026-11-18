import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            SettingsTab("General", systemImage: "gear") {
                SettingsGeneralView()
            }
            SettingsTab("Reading", systemImage: "book.fill") {
                SettingsReadingView()
            }
            SettingsTab("Pronunciations", systemImage: "character.bubble.fill") {
                SettingsPronunciationsView()
                    .frame(height: 520)
            }
        }
        .padding()
        .onAppear(perform: RecorderKeyboardFocus.install)
    }
}
