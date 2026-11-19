import AppKit
import SwiftUI
import Testing

@testable import EasyReader

extension IntegrationTests {
    @MainActor
    struct BackportTableTests {
        struct Item: Identifiable, Equatable {
            let id = UUID()
            var name: String
            var on = false
        }

        final class Model: ObservableObject {
            @Published var rows: [Item]
            @Published var selection: Item.ID?

            init(_ names: [String]) {
                rows = names.map { Item(name: $0) }
            }
        }

        struct Harness: View {
            @ObservedObject var model: Model

            var body: some View {
                BackportTable($model.rows, selection: $model.selection) {
                    BackportTableColumn("Name", value: \.name) { $item in
                        TextField("Name", text: $item.name)
                    }
                    .width(min: 100, ideal: 200)
                    BackportTableColumn("On") { $item in
                        Toggle("On", isOn: $item.on).labelsHidden()
                    }
                    .width(40)
                }
                .onMove { model.rows.move(fromOffsets: $0, toOffset: $1) }
            }
        }

        private let model = Model(["Alpha", "Beta", "Gamma"])
        private let window: NSWindow
        private let tableView: NSTableView

        init() async throws {
            window = makeTestWindow(NSHostingView(rootView: Harness(model: model)), frame: NSRect(x: 200, y: 200, width: 320, height: 200))
            await settle()
            tableView = try #require(firstSubview(NSTableView.self, in: window.contentView))
        }

        private func textField(row: Int) throws -> NSTextField {
            let cell = try #require(tableView.view(atColumn: 0, row: row, makeIfNecessary: true))
            return try #require(firstSubview(NSTextField.self, in: cell))
        }

        private func mouseEvent(_ type: NSEvent.EventType, at windowLocation: NSPoint, timestamp: TimeInterval) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: windowLocation, modifierFlags: [], timestamp: timestamp,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )
        }

        private func click(_ view: NSView) throws {
            let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            let down = try #require(mouseEvent(.leftMouseDown, at: point, timestamp: ProcessInfo.processInfo.systemUptime))
            let up = try #require(mouseEvent(.leftMouseUp, at: point, timestamp: ProcessInfo.processInfo.systemUptime))
            // Posted, not sent, so `NSApp.currentEvent` is set (the table reads it).
            NSApp.postEvent(down, atStart: false)
            NSApp.postEvent(up, atStart: false)
        }

        @Test func showsRowsAndColumns() throws {
            #expect(tableView.numberOfRows == 3)
            #expect(tableView.tableColumns.map(\.title) == ["Name", "On"])
            #expect(tableView.tableColumns[1].width == 40)
            #expect(try textField(row: 0).stringValue == "Alpha")
            #expect(try textField(row: 2).stringValue == "Gamma")
        }

        @Test func editingACellUpdatesItsRow() async throws {
            let field = try textField(row: 1)
            #expect(window.makeFirstResponder(field))
            let editor = try #require(field.currentEditor() as? NSTextView)
            editor.selectAll(nil)
            editor.insertText("Bravo", replacementRange: editor.selectedRange())
            await settle()
            #expect(model.rows.map(\.name) == ["Alpha", "Bravo", "Gamma"])
        }

        @Test func modelChangesRefreshCells() async throws {
            model.rows[1].name = "Bravo"
            await settle()
            #expect(try textField(row: 1).stringValue == "Bravo")

            model.rows.insert(Item(name: "First"), at: 0)
            model.rows.removeLast()
            await settle()
            #expect(tableView.numberOfRows == 3)
            #expect(try (0..<3).map { try textField(row: $0).stringValue } == ["First", "Alpha", "Bravo"])
        }

        @Test func selectionSyncsBothWays() async throws {
            model.selection = model.rows[2].id
            await settle()
            #expect(tableView.selectedRow == 2)

            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            await settle()
            #expect(model.selection == model.rows[0].id)

            model.selection = nil
            await settle()
            #expect(tableView.selectedRow == -1)
        }

        /// Removing the selected row clears the table selection instead of selecting a neighbor on its own.
        @Test func removingSelectedRow() async throws {
            model.selection = model.rows[1].id
            await settle()
            model.rows.remove(at: 1)
            model.selection = nil
            await settle()
            #expect(tableView.numberOfRows == 2)
            #expect(tableView.selectedRow == -1)
        }

        /// A header click sorts the rows themselves (Finder-like string order, stable), again to reverse.
        @Test func headerClickSortsRows() async throws {
            // Two "alpha"s, told apart by `on`, check the sort is stable.
            model.rows = [Item(name: "beta"), Item(name: "alpha", on: true), Item(name: "gamma 10"), Item(name: "gamma 9"), Item(name: "alpha")]
            func order() -> [String] { model.rows.map { $0.name + ($0.on ? "+" : "") } }
            await settle()
            let prototype = try #require(tableView.tableColumns[0].sortDescriptorPrototype)
            #expect(tableView.tableColumns[1].sortDescriptorPrototype == nil, "column without a value isn't sortable")

            tableView.sortDescriptors = [prototype]
            await settle()
            #expect(order() == ["alpha+", "alpha", "beta", "gamma 9", "gamma 10"])
            #expect(try textField(row: 3).stringValue == "gamma 9")

            tableView.sortDescriptors = [prototype.reversedSortDescriptor as! NSSortDescriptor]
            await settle()
            #expect(order() == ["gamma 10", "gamma 9", "beta", "alpha+", "alpha"])
            #expect(tableView.sortDescriptors.count == 1, "arrow stays while sorted")
        }

        /// The header arrow goes away once the rows are no longer in its order (e.g. after a move or edit).
        @Test func sortIndicatorClearsWhenOrderChanges() async throws {
            let prototype = try #require(tableView.tableColumns[0].sortDescriptorPrototype)
            tableView.sortDescriptors = [prototype]
            await settle()
            #expect(tableView.sortDescriptors.count == 1)
            model.rows[0].name = "Zulu"
            await settle()
            #expect(tableView.sortDescriptors.isEmpty)
        }

        /// Dragged rows go through `onMove` with `List.onMove` offsets; the selection follows its row.
        @Test(
            arguments: [
                ([0], 3, ["Beta", "Gamma", "Alpha"]),
                ([2], 0, ["Gamma", "Alpha", "Beta"]),
                ([1], 1, ["Alpha", "Beta", "Gamma"]),
            ] as [([Int], Int, [String])])
        func dragReordersRows(rows: [Int], destination: Int, expected: [String]) async throws {
            let coordinator = try #require(tableView.dataSource as? BackportTable<Item>.Coordinator)
            #expect(coordinator.tableView(tableView, pasteboardWriterForRow: 0) != nil)
            model.selection = model.rows[rows[0]].id
            let selected = model.selection
            await settle()
            #expect(coordinator.move(IndexSet(rows), to: destination))
            await settle()
            #expect(model.rows.map(\.name) == expected)
            #expect(try (0..<3).map { try textField(row: $0).stringValue } == expected)
            #expect(model.selection == selected)
            #expect(tableView.selectedRow == model.rows.firstIndex { $0.id == selected })
        }

        /// Like a standard table: clicking a field in an unselected row only selects the row; in the selected row it edits.
        @Test func clickSelectsRowThenClickEdits() async throws {
            let field = try textField(row: 2)
            try click(field)
            await settle()
            #expect(model.selection == model.rows[2].id)
            #expect(field.currentEditor() == nil)

            try click(field)
            await settle()
            #expect(field.currentEditor() != nil)
            #expect(model.selection == model.rows[2].id)
        }

        /// SwiftUI asks every row's field for first responder on each update, mid-click too: only the clicked one may select.
        @Test func onlyTheClickedFieldSelectsItsRow() throws {
            let table = try #require(tableView as? BackportTableView)
            let fields = try (0..<3).map(textField(row:))
            let row = tableView.rect(ofRow: 2)
            // Left edge of row 2, outside the cell's inset.
            let besideFields = tableView.convert(NSPoint(x: tableView.rect(ofColumn: 0).minX + 1, y: row.midY), to: nil)
            let click = try #require(mouseEvent(.leftMouseDown, at: besideFields, timestamp: 1))
            for field in fields {
                #expect(table.allowsFirstResponder(field, during: click))
            }
            #expect(tableView.selectedRow == -1)

            let fieldCenter = fields[2].convert(NSPoint(x: fields[2].bounds.midX, y: fields[2].bounds.midY), to: nil)
            let onField = try #require(mouseEvent(.leftMouseDown, at: fieldCenter, timestamp: 2))
            #expect(table.allowsFirstResponder(fields[0], during: onField))
            #expect(!table.allowsFirstResponder(fields[2], during: onField))
            #expect(tableView.selectedRow == 2)
            // Still refused for the rest of that click, though the row is now selected.
            #expect(!table.allowsFirstResponder(fields[2], during: onField))
        }

        /// Other controls respond to the first click, without selecting their row.
        @Test func checkboxTogglesOnFirstClick() async throws {
            let cell = try #require(tableView.view(atColumn: 1, row: 1, makeIfNecessary: true))
            let checkbox = try #require(firstSubview(NSButton.self, in: cell))
            try click(checkbox)
            await settle()
            #expect(model.rows[1].on)
            #expect(model.selection == nil)
        }
    }
}
