import SwiftUI

struct SettingsTab<Title: StringProtocol, Content: View>: View {
    private let title: Title
    private let systemImage: String
    private let content: () -> Content

    init(_ title: Title, systemImage: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content
    }

    var body: some View {
        // Fixed width, height fits each tab (the window resizes like System Settings).
        content()
            .frame(width: 640)
            .fixedSize(horizontal: false, vertical: true)
            .tabItem {
                Label(title, systemImage: systemImage)
            }
    }
}

/// Every tab's bottom row: Open Sample Text on the left, the tab's reset button on the right.
struct SettingsFooter<Reset: View>: View {
    private let reset: Reset

    init(@ViewBuilder reset: () -> Reset) {
        self.reset = reset()
    }

    var body: some View {
        HStack {
            SampleTextButton()
            Spacer()
            reset
        }
    }
}

extension HorizontalAlignment {
    private enum ControlAlignment: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat { context[HorizontalAlignment.center] }
    }

    fileprivate static let controlAlignment = Self(ControlAlignment.self)
}

extension View {
    /// A label in a `Form`'s label column for a control without one (before macOS 13, the way KeyboardShortcuts labels its recorder).
    @ViewBuilder func formLabel(_ label: Text) -> some View {
        if #available(macOS 13.0, *) {
            LabeledContent {
                self
            } label: {
                label
            }
        } else {
            HStack(alignment: .firstTextBaseline) {
                label
                labelsHidden()
                    .alignmentGuide(.controlAlignment) { $0[.leading] }
            }
            .alignmentGuide(.leading) { $0[.controlAlignment] }
        }
    }
}
