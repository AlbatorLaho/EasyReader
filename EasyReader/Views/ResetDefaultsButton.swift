import SwiftUI
import Defaults

struct ResetDefaultsButton<Label: View>: View {
    private let label: () -> Label
    private let action: () -> Void
    private let name: String
    @State private var showAlert = false

    init(for name: String, action: @escaping () -> Void, @ViewBuilder label: @escaping () -> Label) {
        self.label = label
        self.action = action
        self.name = name
    }

    init(for name: String, action: @escaping () -> Void) where Label == Text {
        self.init(for: name, action: action, label: { Text("Reset \(name)…") })
    }

    init(for name: String, keys: [Defaults.Keys]) where Label == Text {
        self.init(for: name, action: { Defaults.reset(keys) })
    }

    var body: some View {
        let title = "Reset \(name) settings?"
        let message = "Are you sure you want to reset settings to the defaults?"

        if #available(macOS 12.0, *) {
            Button(role: .destructive) {
                showAlert.toggle()
            } label: {
                label()
            }
            .alert(title, isPresented: $showAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Reset", role: .destructive) {
                    action()
                }
            } message: {
                Text(message)
            }
        } else {
            Button {
                showAlert.toggle()
            } label: {
                label()
            }
            .alert(isPresented: $showAlert) {
                Alert(
                    title: Text(title),
                    message: Text(message),
                    primaryButton: .cancel(),
                    secondaryButton: .destructive(Text("Reset")) {
                        action()
                    }
                )
            }
        }
    }
}
