import AppKit
import MTPCore
import SwiftUI

/// Read-only grid for any QueryResult (insights, process list, previews...). Sorts client-side.
public struct ResultTableView: NSViewRepresentable {
    public var result: QueryResult
    public var onSelect: ((Int?) -> Void)?
    public var menuProvider: ((Int, Int) -> NSMenu?)?

    public init(result: QueryResult, onSelect: ((Int?) -> Void)? = nil, menuProvider: ((Int, Int) -> NSMenu?)? = nil) {
        self.result = result
        self.onSelect = onSelect
        self.menuProvider = menuProvider
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> DataGridView {
        let grid = DataGridView(frame: .zero)
        context.coordinator.parent = self
        context.coordinator.setResult(result)
        grid.dataSource = context.coordinator
        grid.reload()
        return grid
    }

    public func updateNSView(_ grid: DataGridView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.setResult(result) { grid.reload(resetSort: true) }
    }

    @MainActor
    public final class Coordinator: NSObject, DataGridDataSource {
        var parent: ResultTableView?
        var columns: [ResultColumn] = []
        var rows: [[String?]] = []
        var original: [[String?]] = []
        var token = ""

        /// Returns true when the content changed.
        @discardableResult
        func setResult(_ r: QueryResult) -> Bool {
            let t = "\(r.columns.map(\.name))|\(r.rows.count)|\(r.statement.hashValue)|\(r.duration)"
            guard t != token else { return false }
            token = t
            columns = r.columns
            rows = r.rows
            original = r.rows
            return true
        }

        public var gridColumns: [ResultColumn] { columns }
        public var gridRowCount: Int { rows.count }
        public func gridValue(row: Int, column: Int) -> String? { row < rows.count && column < rows[row].count ? rows[row][column] : nil }

        public func gridSortChanged(_ keys: [SortKey]) {
            guard let key = keys.first, let i = columns.firstIndex(where: { $0.name == key.column }) else {
                rows = original
                return
            }
            let numeric = columns[i].isNumeric
            rows = original.sorted { a, b in
                let x = a[i], y = b[i]
                guard let x else { return !key.ascending }
                guard let y else { return key.ascending }
                if numeric, let dx = Double(x), let dy = Double(y) { return key.ascending ? dx < dy : dx > dy }
                let c = x.localizedStandardCompare(y)
                return key.ascending ? c == .orderedAscending : c == .orderedDescending
            }
        }

        public func gridSelectionChanged(rows: IndexSet, column: Int?) {
            parent?.onSelect?(rows.first)
        }

        public func gridMenu(row: Int, column: Int) -> NSMenu? {
            if let m = parent?.menuProvider?(row, column) { return m }
            let menu = NSMenu()
            let value = gridValue(row: row, column: column)
            menu.addItem(ClosureMenuItem("Copy Value") { Pasteboard.copy(value ?? "NULL") })
            menu.addItem(ClosureMenuItem("Copy Row as TSV") { [rows] in
                Pasteboard.copy(rows[row].map { $0 ?? "NULL" }.joined(separator: "\t"))
            })
            menu.addItem(ClosureMenuItem("Copy Column Name") { [columns] in Pasteboard.copy(columns[column].name) })
            return menu
        }
    }
}

/// NSMenuItem with a closure action — keeps context menus short to build.
public final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    public init(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [.command], enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        target = self
        isEnabled = enabled
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}
