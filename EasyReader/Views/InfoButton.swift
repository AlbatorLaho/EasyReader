import SwiftUI

/// ⓘ with a one-line `summary` tooltip; a click shows `content` in a popover.
struct InfoButton<Content: View>: View {
    private let summary: String
    private let content: () -> Content
    @State private var isShown = false
    @State private var isHovered = false

    init(_ summary: String, @ViewBuilder content: @escaping () -> Content) {
        self.summary = summary
        self.content = content
    }

    var body: some View {
        Button {
            isShown.toggle()
        } label: {
            Image(systemName: isHovered || isShown ? "info.circle.fill" : "info.circle")
                .foregroundColor(.accentColor)
        }
        .buttonStyle(.borderless)
        .onHover { isHovered = $0 }
        .help("\(summary) Click for details.")
        .accessibilityLabel(Text("More Info"))
        .popover(isPresented: $isShown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 340, alignment: .leading)
            .padding()
        }
    }
}

extension InfoButton where Content == InfoText {
    init(_ summary: String, title: String, _ paragraphs: String...) {
        self.init(summary) { InfoText(title: title, paragraphs: paragraphs) }
    }
}

struct InfoText: View {
    let title: String
    let paragraphs: [String]

    var body: some View {
        Text(title).font(.headline)
        ForEach(paragraphs, id: \.self) { Text($0) }
    }
}

extension View {
    /// The view with an `InfoButton` after it.
    func info(_ summary: String, title: String, _ paragraphs: String...) -> some View {
        info(summary) { InfoText(title: title, paragraphs: paragraphs) }
    }

    func info<Content: View>(_ summary: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        HStack(spacing: 4) {
            self
            InfoButton(summary, content: content)
        }
    }
}
