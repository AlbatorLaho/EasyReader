//
//  PronunciationTable.swift
//  EasyReader
//
//  Created by Ewalk on 2025-01-18.
//

import SwiftUI

struct PronunciationTable: NSViewRepresentable {
    @Binding var data: [Pronunciation]
    @Binding var selection: Pronunciation?

    init(_ data: Binding<[Pronunciation]>, selection: Binding<Pronunciation?>) {
        _data = data
        _selection = selection
    }

    func makeCoordinator() -> Coordinator {
        Log.settings.debug("PronunciationTable.makeCoordinator")
        return Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        Log.settings.debug("PronunciationTable.makeNSView")
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false

        let tableView = NSTableView()
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.style = .plain
//        tableView.style = .fullWidth
        tableView.rowSizeStyle = .small
//        tableView.gridStyleMask = [.solidVerticalGridLineMask, .solidHorizontalGridLineMask]
        tableView.gridStyleMask = .solidVerticalGridLineMask
        tableView.usesAlternatingRowBackgroundColors = true

        tableView.addTableColumn(NSTableColumn("Search"))
        tableView.addTableColumn(NSTableColumn("Replace"))
//        tableView.addTableColumn(NSTableColumn("Domain"))
        tableView.addTableColumn(NSTableColumn("Ignore Case"))
        tableView.addTableColumn(NSTableColumn("Enabled"))

//        context.coordinator.dataSource = NSTableViewDiffableDataSource<String, Int>(tableView: tableView) { tableView, tableColumn, row, identifier in
//            print("get cell")
//            guard let cell = tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? NSTableCellView else {
//                print("couldn't get cell")
//                return NSView()
//            }
//            print("got cell")
//            cell.textField?.stringValue = String(identifier)
//            return cell
//        }
//        tableView.dataSource = context.coordinator.dataSource
//        tableView.addTableColumn(NSTableColumn("Search"))
//
//        if let dataSource = context.coordinator.dataSource {
////            var snapshot = dataSource.snapshot()
//            var snapshot = NSDiffableDataSourceSnapshot<String, Int>()
//            snapshot.appendSections(["TEST"])
//            snapshot.appendItems([0, 1, 2, 3], toSection: "TEST")
//            dataSource.apply(snapshot, animatingDifferences: false)
//        }

        scrollView.documentView = tableView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        Log.settings.debug("PronunciationTable.updateNSView")
        if let tableView = nsView.documentView as? NSTableView {
            tableView.reloadData()
            if let selection, let index = data.firstIndex(of: selection) {
                tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            }
        }
//        if let dataSource = context.coordinator.dataSource {
//            var snapshot = dataSource.snapshot()
//            dataSource.apply(snapshot, animatingDifferences: false)
//        }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
        var parent: PronunciationTable
//        var data: Binding<[Pronunciation]>
//        var dataSource: NSTableViewDiffableDataSource<String, Int>?

        init(_ parent: PronunciationTable) {
            self.parent = parent
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            return parent.data.count
        }

//        func tableView(_ tableView: NSTableView, dataCellFor tableColumn: NSTableColumn?, row: Int) -> NSCell? {}
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn else { return nil }
            var cell = tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil)
            if cell == nil {
//                print("creating view \(row) \(tableColumn.identifier.rawValue)")
                switch tableColumn.identifier.rawValue {
                    case "Search", "Replace":
                        let textField = NSTextField()
                        textField.isEditable = true
//                        textField.isBezeled = false
                        textField.isBordered = false
                        textField.drawsBackground = false
                        textField.target = self
                        textField.delegate = self
                        cell = textField
//                    case "Domain":
////                        let popUpButton = NSPopUpButton(title: "App Picker", pullDownMenu: NSMenu(title: "App Items"))
//                        let popUpButton = NSPopUpButton()
//                        popUpButton.menu = NSMenu()
//                        popUpButton.menu?.items = [
//                            .init(title: "All Apps", action: nil, keyEquivalent: ""),
//                            .separator(),
//                            .init(title: "TextEdit", action: nil, keyEquivalent: ""),
//                            .init(title: "Brave Browser", action: nil, keyEquivalent: ""),
//                            .separator(),
//                            .init(title: "Other App...", action: nil, keyEquivalent: ""),
//                        ]
////                        popUpButton.addItem(withTitle: "All Apps")
////                        popUpButton.menu?.addItem(.separator())
////                        popUpButton.addItems(withTitles: ["TextEdit", "Brave Browser"])
////                        popUpButton.menu?.addItem(.separator())
////                        popUpButton.addItem(withTitle: "Other App...")
//                        popUpButton.isBordered = false
////                        popUpButton.bezelStyle = .recessed
////                        popUpButton.bezelStyle = .roundRect
////                        popUpButton.bezelStyle = .inline
//                        popUpButton.action = #selector(onPopUpButtonChange(_:))
//                        popUpButton.target = self
//                        cell = popUpButton
                    case "Ignore Case", "Enabled":
                        let checkBox = NSButton(checkboxWithTitle: "", target: self, action: #selector(onCheckBoxChange(_:)))
//                        TODO: center buttons in the column?
//                        checkBox.sizeToFit()
//                        checkBox.autoresizingMask = [.width, .minXMargin, .minXMargin]
//                        checkBox.translatesAutoresizingMaskIntoConstraints = false
//                        checkBox.viewDidMoveToSuperview()
//                        NSLayoutConstraint.activate([
//                            checkBox.centerXAnchor.constraint(equalTo: checkBox.superview!.centerXAnchor),
//                            checkBox.centerYAnchor.constraint(equalTo: checkBox.superview!.centerYAnchor)
//                        ])
//                        NSHostingView(rootView: Toggle("", isOn: $data[row].ignoreCase))
                        cell = checkBox
                    default: return nil
                }
            } else {
//                print("reusing view \(row) \(tableColumn.identifier.rawValue)")
            }

            switch tableColumn.identifier.rawValue {
                case "Search":
                    if let textField = cell as? NSTextField {
                        textField.stringValue = parent.data[row].search
                    }
                case "Replace":
                    if let textField = cell as? NSTextField {
                        textField.stringValue = parent.data[row].replace
                    }
//                case "Domain":
//                    if let popUpButton = cell as? NSPopUpButton {
////                        popUpButton.selectItem(withTitle: parent.data[row].domain ?? "All Apps")
////                        popUpButton.stringValue = item.domain ?? "All Apps"
//                    }
                case "Ignore Case":
                    if let checkBox = cell as? NSButton {
                        checkBox.state = parent.data[row].ignoreCase ? .on : .off
                    }
                case "Enabled":
                    if let checkBox = cell as? NSButton {
                        checkBox.state = parent.data[row].enabled ? .on : .off
                    }
                default: return nil
            }

            if let control = cell as? NSControl {
                control.tag = row
            }
            cell?.identifier = tableColumn.identifier
            return cell
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            DispatchQueue.main.async {
                guard let textField = obj.object as? NSTextField else { return }
                let row = textField.tag
                guard self.parent.data.indices.contains(row) else { return }
                if textField.identifier?.rawValue == "Search" {
                    self.parent.data[row].search = textField.stringValue
                } else if textField.identifier?.rawValue == "Replace" {
                    self.parent.data[row].replace = textField.stringValue
                }
            }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            DispatchQueue.main.async {
                guard let tableView = notification.object as? NSTableView else { return }
                let row = tableView.selectedRow  // -1 when nothing is selected
                self.parent.selection = self.parent.data.indices.contains(row) ? self.parent.data[row] : nil
            }
        }

//        @objc func onPopUpButtonChange(_ sender: NSPopUpButton) {
//            let row = sender.tag
//            print("\(row): \(sender.stringValue)")
//            parent.data[row].domain = sender.stringValue
//        }

        @objc func onCheckBoxChange(_ sender: NSButton) {
            let row = sender.tag
            guard parent.data.indices.contains(row) else { return }
            if sender.identifier?.rawValue == "Ignore Case" {
                parent.data[row].ignoreCase = (sender.state == .on)
            } else if sender.identifier?.rawValue == "Enabled" {
                parent.data[row].enabled = (sender.state == .on)
            }
        }
    }
}

extension NSTableColumn {
    convenience init(_ title: String) {
        self.init(identifier: NSUserInterfaceItemIdentifier(title))
        self.title = title
        self.sizeToFit()
//        self.isEditable = true
    }
}
