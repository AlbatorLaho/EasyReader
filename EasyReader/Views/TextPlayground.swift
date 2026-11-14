import SwiftUI

struct TextPlayground<Label: View>: View {
    private let label: () -> Label
    private let defaultText: () -> String
    @State private var text = ""

    init(defaultText: @escaping () -> String, @ViewBuilder label: @escaping () -> Label = { Text("Playground") }) {
        self.label = label
        self.defaultText = defaultText
    }

    init(_ title: String, defaultText: @escaping () -> String) where Label == Text {
        self.init(defaultText: defaultText, label: { Text(title) })
    }

    var body: some View {
        GroupBox {
            TextEditor(text: $text)
                .font(.system(size: 24))
                .clipShape(.rect(cornerRadius: 5))
                .onAppear {
                    if text.isEmpty {
                        text = defaultText()
                    }
                }
        } label: {
            HStack {
                label()
                Spacer()
                Button("Reset Text", systemImage: "arrow.clockwise") {
                    text = defaultText()
                }
            }
        }
    }
}
