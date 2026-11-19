import AppKit
import Defaults
import SwiftUI
import Testing

@testable import EasyReader

extension IntegrationTests {
    @MainActor
    struct SettingsPronunciationsViewTests {
        private let window: NSWindow
        private let tableView: NSTableView
        private let rules = [
            Pronunciation(search: "GUI", replace: "gooey"),
            Pronunciation(search: "(", replace: "x", isRegex: true),
            Pronunciation(search: "tomato", replace: "təˈmɑːtəʊ", isPhonetic: true),
        ]

        init() async throws {
            Defaults[.pronunciations] = rules
            window = makeTestWindow(NSHostingView(rootView: SettingsPronunciationsView()), frame: NSRect(x: 100, y: 100, width: 800, height: 500))
            await settle(0.3)
            tableView = try #require(firstSubview(NSTableView.self, in: window.contentView))
        }

        private var tableFrame: NSRect {
            tableView.enclosingScrollView.map { $0.convert($0.bounds, to: nil) } ?? .zero
        }

        /// The options box is always there (disabled without a selection), so selecting never resizes the table.
        @Test func selectingKeepsLayout() async throws {
            let unselected = tableFrame
            #expect(unselected.height > 100)
            for row in [0, 1, 2, 0] {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                await settle()
                #expect(tableFrame == unselected, "row \(row) (\(rules[row].search))")
            }
            tableView.deselectAll(nil)
            await settle()
            #expect(tableFrame == unselected)
        }
    }
}
