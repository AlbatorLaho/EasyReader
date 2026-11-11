//
//  BackportTable.swift
//  EasyReader
//

import AppKit
import SwiftUI

/// A table shaped like SwiftUI's `Table` (rows, single selection, a builder of columns), backed by an
/// `NSTableView` because `Table` needs macOS 12. Cells host SwiftUI views and edit their row through a
/// `Binding<Row>`, so moving to `Table` later should mostly be a rename.
///
///     BackportTable($people, selection: $selected) {
///         BackportTableColumn("Name", value: \.name) { $person in TextField("Name", text: $person.name) }
///             .width(min: 80, ideal: 120)
///     }
///     .onMove { people.move(fromOffsets: $0, toOffset: $1) }
///
/// Columns with a `value` sort by a header click: it sorts `rows` itself (stable; click again to
/// reverse). The header arrow stays only while `rows` is still in that order (e.g. not after a move).
/// With `onMove`, rows can be dragged to reorder (`Table` has no direct equivalent before macOS 14).
struct BackportTable<Row: Identifiable>: NSViewRepresentable {
    @Binding var rows: [Row]
    @Binding var selection: Row.ID?
    let columns: [BackportTableColumn<Row>]
    var rowHeight: CGFloat = 24
    private var onMove: ((IndexSet, Int) -> Void)?

    init(
        _ rows: Binding<[Row]>,
        selection: Binding<Row.ID?>,
        @BackportTableColumnBuilder<Row> columns: () -> [BackportTableColumn<Row>]
    ) {
        _rows = rows
        _selection = selection
        self.columns = columns()
    }

    /// Lets rows be dragged to reorder; `perform` gets the dragged offsets and the destination offset
    /// (in the order before the move), like `List.onMove`.
    func onMove(perform: @escaping (IndexSet, Int) -> Void) -> Self {
        var table = self
        table.onMove = perform
        return table
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = BackportTableView()
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.style = .fullWidth
        tableView.rowHeight = rowHeight
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        for (index, column) in columns.enumerated() {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("\(index)"))
            tableColumn.title = column.title
            if let minWidth = column.minWidth { tableColumn.minWidth = minWidth }
            if let maxWidth = column.maxWidth { tableColumn.maxWidth = maxWidth }
            if let width = column.idealWidth ?? column.minWidth { tableColumn.width = width }
            tableColumn.resizingMask = column.minWidth != nil && column.minWidth == column.maxWidth ? [] : [.autoresizingMask, .userResizingMask]
            if column.areInIncreasingOrder != nil {
                tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: "\(index)", ascending: true)
            }
            tableView.addTableColumn(tableColumn)
        }
        if onMove != nil {
            tableView.registerForDraggedTypes([Coordinator.rowType])
            tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        }

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = tableView
        context.coordinator.attach(to: tableView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tableView = scrollView.documentView as? NSTableView else { return }
        context.coordinator.update(self, tableView: tableView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private var parent: BackportTable
        private var ids: [Row.ID]
        /// Rows as last shown, to skip refreshing cells when only something else (e.g. selection) changed.
        private var shownRows: [Row]
        /// Set while we change the table's selection ourselves, so it isn't echoed back into the binding.
        private var isSyncingSelection = false

        init(_ parent: BackportTable) {
            self.parent = parent
            ids = parent.rows.map(\.id)
            shownRows = parent.rows
        }

        func attach(to tableView: NSTableView) {
            syncSelection(of: tableView)
        }

        func update(_ parent: BackportTable, tableView: NSTableView) {
            self.parent = parent
            let newIDs = parent.rows.map(\.id)
            if newIDs != ids {
                ids = newIDs
                isSyncingSelection = true
                tableView.reloadData()
                isSyncingSelection = false
            } else if !Self.areEqual(shownRows, parent.rows) {
                // Same rows, new values: refresh visible cells in place (keeps an active text field editing).
                let visible = tableView.rows(in: tableView.visibleRect)
                for row in visible.location..<visible.upperBound {
                    for column in parent.columns.indices {
                        let cell = tableView.view(atColumn: column, row: row, makeIfNecessary: false) as? HostingCell
                        cell?.host.rootView = content(column: column, row: row)
                    }
                }
            }
            shownRows = parent.rows
            if let sort = tableView.sortDescriptors.first, !isSorted(parent.rows, by: sort) {
                tableView.sortDescriptors = []
            }
            syncSelection(of: tableView)
        }

        // MARK: Sorting

        /// `areInIncreasingOrder` for a header sort descriptor (key = column index), reversed when descending.
        private func comparator(for sort: NSSortDescriptor) -> ((Row, Row) -> Bool)? {
            guard let key = sort.key, let column = Int(key), parent.columns.indices.contains(column),
                let less = parent.columns[column].areInIncreasingOrder
            else { return nil }
            return sort.ascending ? less : { less($1, $0) }
        }

        private func isSorted(_ rows: [Row], by sort: NSSortDescriptor) -> Bool {
            guard let less = comparator(for: sort) else { return false }
            return zip(rows, rows.dropFirst()).allSatisfy { !less($1, $0) }
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let sort = tableView.sortDescriptors.first, let less = comparator(for: sort) else { return }
            let sorted = parent.rows.enumerated()
                .sorted { less($0.element, $1.element) || (!less($1.element, $0.element) && $0.offset < $1.offset) }
                .map(\.element)
            if sorted.map(\.id) != ids { parent.rows = sorted }
        }

        // MARK: Reordering

        static var rowType: NSPasteboard.PasteboardType { .init("HawkRaven.EasyReader.BackportTableRow") }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard parent.onMove != nil else { return nil }
            let item = NSPasteboardItem()
            item.setString(String(row), forType: Self.rowType)
            return item
        }

        func tableView(
            _ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
            proposedDropOperation dropOperation: NSTableView.DropOperation
        ) -> NSDragOperation {
            guard parent.onMove != nil, info.draggingSource as? NSTableView === tableView else { return [] }
            // Between rows only (insertion line), never onto one.
            if dropOperation == .on { tableView.setDropRow(row, dropOperation: .above) }
            return .move
        }

        func tableView(
            _ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
            dropOperation: NSTableView.DropOperation
        ) -> Bool {
            let rows = info.draggingPasteboard.pasteboardItems?.compactMap { $0.string(forType: Self.rowType).flatMap(Int.init) }
            return move(IndexSet(rows ?? []), to: row)
        }

        /// Moves `rows` to before `destination` (offsets before the move) through `onMove`.
        @discardableResult
        func move(_ rows: IndexSet, to destination: Int) -> Bool {
            guard let onMove = parent.onMove, !rows.isEmpty,
                rows.allSatisfy(parent.rows.indices.contains), (0...parent.rows.count).contains(destination)
            else { return false }
            onMove(rows, destination)
            return true
        }

        /// Whether two row arrays are equal, when `Row` is `Equatable` (else always `false`: refresh).
        /// Cells reading state other than their row update only through their own SwiftUI observation.
        private static func areEqual(_ old: [Row], _ new: [Row]) -> Bool {
            func equals<T: Equatable>(_ old: T) -> Bool { (new as Any as? T) == old }
            guard let old = old as Any as? any Equatable else { return false }
            return equals(old)
        }

        private func syncSelection(of tableView: NSTableView) {
            let target = parent.selection.flatMap { ids.firstIndex(of: $0) } ?? -1
            guard tableView.selectedRow != target else { return }
            isSyncingSelection = true
            if target >= 0 {
                tableView.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
                tableView.scrollRowToVisible(target)
            } else {
                tableView.deselectAll(nil)
            }
            isSyncingSelection = false
        }

        private func content(column: Int, row: Int) -> AnyView {
            let fallback = parent.rows[row]
            let id = fallback.id
            let binding = Binding<Row>(
                get: { [weak self] in self?.parent.rows.first { $0.id == id } ?? fallback },
                set: { [weak self] newValue in
                    guard let self, let index = self.parent.rows.firstIndex(where: { $0.id == id }) else { return }
                    self.parent.rows[index] = newValue
                }
            )
            return parent.columns[column].content(binding)
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent.rows.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let identifier = tableColumn?.identifier,
                let column = Int(identifier.rawValue),
                parent.columns.indices.contains(column),
                parent.rows.indices.contains(row)
            else { return nil }
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? HostingCell ?? HostingCell(identifier: identifier)
            cell.host.rootView = content(column: column, row: row)
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncingSelection, let tableView = notification.object as? NSTableView else { return }
            let row = tableView.selectedRow
            let id = ids.indices.contains(row) ? ids[row] : nil
            if parent.selection != id { parent.selection = id }
        }
    }
}

/// A column of `BackportTable`, like SwiftUI's `TableColumn`.
struct BackportTableColumn<Row> {
    let title: String
    let content: (Binding<Row>) -> AnyView
    /// Sort order for a header click (`nil`: not sortable).
    let areInIncreasingOrder: ((Row, Row) -> Bool)?
    fileprivate(set) var minWidth: CGFloat?
    fileprivate(set) var idealWidth: CGFloat?
    fileprivate(set) var maxWidth: CGFloat?

    init<Content: View>(_ title: String, @ViewBuilder content: @escaping (Binding<Row>) -> Content) {
        self.init(title, areInIncreasingOrder: nil, content: content)
    }

    /// A column sortable by `value`, like `TableColumn(_:value:content:)`.
    init<Value: Comparable, Content: View>(
        _ title: String, value: @escaping (Row) -> Value, @ViewBuilder content: @escaping (Binding<Row>) -> Content
    ) {
        self.init(title, areInIncreasingOrder: { value($0) < value($1) }, content: content)
    }

    /// A column sortable by a string `value`, compared like Finder names (case-insensitive, numbers by value).
    init<Content: View>(
        _ title: String, value: @escaping (Row) -> String, @ViewBuilder content: @escaping (Binding<Row>) -> Content
    ) {
        self.init(
            title, areInIncreasingOrder: { value($0).localizedStandardCompare(value($1)) == .orderedAscending },
            content: content)
    }

    private init<Content: View>(
        _ title: String, areInIncreasingOrder: ((Row, Row) -> Bool)?,
        @ViewBuilder content: @escaping (Binding<Row>) -> Content
    ) {
        self.title = title
        self.areInIncreasingOrder = areInIncreasingOrder
        // Leading-aligned, like `Table` cells.
        self.content = { AnyView(content($0).frame(maxWidth: .infinity, alignment: .leading)) }
    }

    func width(_ width: CGFloat) -> Self {
        self.width(min: width, ideal: width, max: width)
    }

    func width(min: CGFloat? = nil, ideal: CGFloat? = nil, max: CGFloat? = nil) -> Self {
        var column = self
        column.minWidth = min
        column.idealWidth = ideal
        column.maxWidth = max
        return column
    }
}

@resultBuilder
enum BackportTableColumnBuilder<Row> {
    static func buildExpression(_ column: BackportTableColumn<Row>) -> [BackportTableColumn<Row>] { [column] }
    static func buildBlock(_ columns: [BackportTableColumn<Row>]...) -> [BackportTableColumn<Row>] { columns.flatMap { $0 } }
    static func buildOptional(_ columns: [BackportTableColumn<Row>]?) -> [BackportTableColumn<Row>] { columns ?? [] }
    static func buildEither(first columns: [BackportTableColumn<Row>]) -> [BackportTableColumn<Row>] { columns }
    static func buildEither(second columns: [BackportTableColumn<Row>]) -> [BackportTableColumn<Row>] { columns }
}

/// Standard table click behavior for hosted SwiftUI controls: a click on a text field in an unselected
/// row selects the row without editing; once the row is selected, a click edits the field. Other
/// controls (checkboxes, menus) respond to the first click without selecting the row.
///
/// SwiftUI handles the click itself and asks for first responder with no event, so the click is read
/// from `NSApp.currentEvent`. It also checks every row's field whenever it updates (also mid-click), so
/// only the field under the click counts; the click is then refused for its whole duration.
final class BackportTableView: NSTableView {
    private var refusedClick: TimeInterval?

    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        allowsFirstResponder(responder, during: NSApp.currentEvent)
    }

    func allowsFirstResponder(_ responder: NSResponder, during click: NSEvent?) -> Bool {
        guard let click, click.type == .leftMouseDown, click.window === window,
            let view = responder as? NSView, view is NSTextField || view is NSText
        else { return true }
        if refusedClick == click.timestamp { return false }
        guard view.bounds.contains(view.convert(click.locationInWindow, from: nil)) else { return true }
        let row = row(for: view)
        guard row >= 0, !isRowSelected(row) else { return true }
        refusedClick = click.timestamp
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        window?.makeFirstResponder(self)
        return false
    }
}

private final class HostingCell: NSTableCellView {
    let host = NSHostingView(rootView: AnyView(EmptyView()))

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            host.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            host.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
