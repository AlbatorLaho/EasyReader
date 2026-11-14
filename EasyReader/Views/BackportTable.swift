import AppKit
import SwiftUI

/// SwiftUI `Table` look-alike over `NSTableView` (`Table` needs macOS 12), so moving to `Table` later is mostly a rename.
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

    /// Offsets like `List.onMove`.
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
        private var shownRows: [Row]
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
                // Refresh in place so an active text field keeps editing; also rows prepared off screen.
                tableView.enumerateAvailableRowViews { rowView, row in
                    for column in parent.columns.indices {
                        (rowView.view(atColumn: column) as? HostingCell)?.host.rootView = content(column: column, row: row)
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

        @discardableResult
        func move(_ rows: IndexSet, to destination: Int) -> Bool {
            guard let onMove = parent.onMove, !rows.isEmpty,
                rows.allSatisfy(parent.rows.indices.contains), (0...parent.rows.count).contains(destination)
            else { return false }
            onMove(rows, destination)
            return true
        }

        /// Always `false` unless `Row` is `Equatable`.
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
                    guard let self, let index = parent.rows.firstIndex(where: { $0.id == id }) else { return }
                    parent.rows[index] = newValue
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

struct BackportTableColumn<Row> {
    let title: String
    let content: (Binding<Row>) -> AnyView
    let areInIncreasingOrder: ((Row, Row) -> Bool)?
    fileprivate(set) var minWidth: CGFloat?
    fileprivate(set) var idealWidth: CGFloat?
    fileprivate(set) var maxWidth: CGFloat?

    init<Content: View>(_ title: String, @ViewBuilder content: @escaping (Binding<Row>) -> Content) {
        self.init(title, areInIncreasingOrder: nil, content: content)
    }

    init<Value: Comparable, Content: View>(
        _ title: String, value: @escaping (Row) -> Value, @ViewBuilder content: @escaping (Binding<Row>) -> Content
    ) {
        self.init(title, areInIncreasingOrder: { value($0) < value($1) }, content: content)
    }

    /// Compares like Finder names.
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

/// A click on a text field in an unselected row only selects the row, like a standard table.
final class BackportTableView: NSTableView {
    private var refusedClick: TimeInterval?

    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        // SwiftUI asks without an event.
        allowsFirstResponder(responder, during: NSApp.currentEvent)
    }

    func allowsFirstResponder(_ responder: NSResponder, during click: NSEvent?) -> Bool {
        guard let click, click.type == .leftMouseDown, click.window === window,
            let view = responder as? NSView, view is NSTextField || view is NSText
        else { return true }
        if refusedClick == click.timestamp { return false }
        // SwiftUI checks every row's field on each update, so only the one under the click counts.
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
