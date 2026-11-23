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
        .background(WindowReporter { SettingsOpener.reportedWindow = $0 })
        .onAppear(perform: RecorderKeyboardFocus.install)
    }
}

private struct WindowReporter: NSViewRepresentable {
    let report: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { ReportingView(report: report) }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ReportingView: NSView {
        let report: (NSWindow) -> Void

        init(report: @escaping (NSWindow) -> Void) {
            self.report = report
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            if let window { report(window) }
        }
    }
}
