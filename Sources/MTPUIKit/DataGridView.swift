import AppKit
import MTPCore

public enum GridCellState {
    case normal, edited, inserted, deleted
}

@MainActor
public protocol DataGridDataSource: AnyObject {
    var gridColumns: [ResultColumn] { get }
    var gridRowCount: Int { get }
    func gridValue(row: Int, column: Int) -> String?
    func gridCellState(row: Int, column: Int) -> GridCellState
    func gridCanEdit(column: Int) -> Bool
    func gridDidEdit(row: Int, column: Int, value: CellEdit)
    func gridDeleteRows(_ rows: IndexSet)
    func gridMenu(row: Int, column: Int) -> NSMenu?
    func gridSortChanged(_ keys: [SortKey])
    func gridSelectionChanged(rows: IndexSet, column: Int?)
    /// Double-click on a value that is too big to edit inline (JSON, long text).
    func gridOpenEditor(row: Int, column: Int)
}

public extension DataGridDataSource {
    func gridCellState(row: Int, column: Int) -> GridCellState { .normal }
    func gridCanEdit(column: Int) -> Bool { false }
    func gridDidEdit(row: Int, column: Int, value: CellEdit) {}
    func gridDeleteRows(_ rows: IndexSet) {}
    func gridMenu(row: Int, column: Int) -> NSMenu? { nil }
    func gridSortChanged(_ keys: [SortKey]) {}
    func gridSelectionChanged(rows: IndexSet, column: Int?) {}
    func gridOpenEditor(row: Int, column: Int) {}
}

/// Spreadsheet-like grid: virtualised NSTableView, focused cell, inline editing,
/// TablePlus colors for pending changes, and keyboard-first navigation.
@MainActor
public final class DataGridView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    public weak var dataSource: DataGridDataSource?
    public let tableView = GridTableView()
    public let scrollView = NSScrollView()
    public private(set) var focusedColumn: Int?
    public var nullText = "NULL"
    public var showsRowNumbers = true
    private var columnSignature: [String] = []
    private var editing: (row: Int, column: Int)?
    static let rowNumberID = NSUserInterfaceItemIdentifier("__rownum")

    public override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        tableView.grid = self
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.gridStyleMask = []
        tableView.gridColor = NSColor.separatorColor.withAlphaComponent(0.16)
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.rowHeight = 24
        tableView.style = .plain
        tableView.target = self
        tableView.doubleAction = #selector(doubleClicked(_:))
        tableView.headerView = NSTableHeaderView()
        tableView.focusRingType = .none

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: Public API

    /// Rebuilds columns when they changed, then reloads rows.
    public func reload(resetSort: Bool = false) {
        guard let ds = dataSource else { return }
        let sig = ds.gridColumns.map { "\($0.name):\($0.typeName)" }
        if sig != columnSignature {
            columnSignature = sig
            rebuildColumns(ds)
            focusedColumn = ds.gridColumns.isEmpty ? nil : 0
        } else if resetSort {
            tableView.sortDescriptors = []
        }
        tableView.reloadData()
    }

    public func reloadRows(_ rows: IndexSet) {
        guard !rows.isEmpty else { return }
        tableView.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
    }

    public var selectedRows: IndexSet { tableView.selectedRowIndexes }

    public func selectRow(_ row: Int, column: Int? = nil) {
        guard row >= 0, row < tableView.numberOfRows else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        if let column { setFocusedColumn(column) }
        tableView.scrollRowToVisible(row)
    }

    public func beginEditingFocusedCell() {
        let row = tableView.selectedRow
        guard row >= 0, let col = focusedColumn else { return }
        beginEditing(row: row, column: col)
    }

    private func dataColumnIndex(forTableColumn index: Int) -> Int? {
        guard index >= 0, index < tableView.tableColumns.count else { return nil }
        let id = tableView.tableColumns[index].identifier
        if id == Self.rowNumberID { return nil }
        return Int(id.rawValue)
    }

    private func tableColumnIndex(forDataColumn c: Int) -> Int? {
        tableView.tableColumns.firstIndex { $0.identifier.rawValue == String(c) }
    }

    func setFocusedColumn(_ c: Int?) {
        let old = focusedColumn
        focusedColumn = c
        let rows = tableView.selectedRowIndexes
        var cols = IndexSet()
        for x in [old, c].compactMap({ $0 }) { if let i = tableColumnIndex(forDataColumn: x) { cols.insert(i) } }
        if !rows.isEmpty, !cols.isEmpty { tableView.reloadData(forRowIndexes: rows, columnIndexes: cols) }
        if let c, let i = tableColumnIndex(forDataColumn: c) { tableView.scrollColumnToVisible(i) }
        dataSource?.gridSelectionChanged(rows: rows, column: c)
    }

    private func rebuildColumns(_ ds: DataGridDataSource) {
        for c in tableView.tableColumns.reversed() { tableView.removeTableColumn(c) }
        if showsRowNumbers {
            let rn = NSTableColumn(identifier: Self.rowNumberID)
            rn.title = ""
            rn.headerCell = GridHeaderCell(name: "", type: nil)
            rn.width = 44
            rn.minWidth = 28
            rn.isEditable = false
            rn.resizingMask = .userResizingMask
            tableView.addTableColumn(rn)
        }
        let sampleRows = min(ds.gridRowCount, 60)
        for (i, col) in ds.gridColumns.enumerated() {
            let tc = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(i)))
            tc.title = col.name
            tc.headerCell = GridHeaderCell(name: col.name, type: nil, kind: nil)
            tc.headerToolTip = "\(col.name) — \(col.typeName)"
            tc.sortDescriptorPrototype = NSSortDescriptor(key: col.name, ascending: true)
            // Measure real text so timestamps and UUIDs are not cut, capped to keep wide text readable.
            let font = GridCellView.font(for: col.kind)
            var width = GridHeaderCell.width(name: col.name, type: nil)
            for r in 0..<sampleRows {
                let v = ds.gridValue(row: r, column: i) ?? "NULL"
                width = max(width, (String(v.prefix(80)) as NSString).size(withAttributes: [.font: font]).width + 32)
            }
            tc.width = min(max(width.rounded(.up), 64), 380)
            tc.minWidth = 40
            tc.maxWidth = 4000
            tableView.addTableColumn(tc)
        }
    }

    // MARK: NSTableViewDataSource / Delegate

    public func numberOfRows(in tableView: NSTableView) -> Int {
        dataSource?.gridRowCount ?? 0
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let ds = dataSource, let tableColumn else { return nil }
        if tableColumn.identifier == Self.rowNumberID {
            let cell = (tableView.makeView(withIdentifier: Self.rowNumberID, owner: nil) as? GridCellView) ?? GridCellView(identifier: Self.rowNumberID)
            cell.configureRowNumber(row + 1, state: ds.gridCellState(row: row, column: -1))
            return cell
        }
        guard let c = Int(tableColumn.identifier.rawValue), c < ds.gridColumns.count else { return nil }
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? GridCellView) ?? GridCellView(identifier: id)
        let column = ds.gridColumns[c]
        let isFocused = c == focusedColumn && tableView.isRowSelected(row)
        cell.configure(value: ds.gridValue(row: row, column: c), column: column, state: ds.gridCellState(row: row, column: c),
                       nullText: nullText, focused: isFocused)
        cell.textField?.delegate = self
        return cell
    }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        (tableView.makeView(withIdentifier: GridRowView.id, owner: nil) as? GridRowView) ?? GridRowView()
    }

    public func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        let keys = tableView.sortDescriptors.compactMap { d in d.key.map { SortKey(column: $0, ascending: d.ascending) } }
        dataSource?.gridSortChanged(Array(keys.prefix(1)))
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        tableView.reloadData(forRowIndexes: IndexSet(integersIn: 0..<tableView.numberOfRows).intersection(visibleRows()),
                             columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
        dataSource?.gridSelectionChanged(rows: tableView.selectedRowIndexes, column: focusedColumn)
    }

    private func visibleRows() -> IndexSet {
        let r = tableView.rows(in: tableView.visibleRect)
        return IndexSet(integersIn: r.location..<(r.location + r.length))
    }

    public func tableView(_ tableView: NSTableView, shouldEdit tableColumn: NSTableColumn?, row: Int) -> Bool { false }

    // MARK: Editing

    @objc private func doubleClicked(_ sender: Any?) {
        let row = tableView.clickedRow
        guard row >= 0, let c = dataColumnIndex(forTableColumn: tableView.clickedColumn) else { return }
        setFocusedColumn(c)
        beginEditing(row: row, column: c)
    }

    func beginEditing(row: Int, column c: Int) {
        guard let ds = dataSource, ds.gridCanEdit(column: c), let tc = tableColumnIndex(forDataColumn: c) else {
            if let ds = dataSource { ds.gridOpenEditor(row: row, column: c) }
            return
        }
        let value = ds.gridValue(row: row, column: c)
        let kind = ds.gridColumns[c].kind
        if kind == .json || (value?.count ?? 0) > 200 || (value?.contains("\n") ?? false) {
            ds.gridOpenEditor(row: row, column: c)
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        guard let cell = tableView.view(atColumn: tc, row: row, makeIfNecessary: true) as? GridCellView, let field = cell.textField else { return }
        editing = (row, c)
        field.isEditable = true
        field.stringValue = value ?? ""
        field.textColor = .labelColor
        field.font = cell.valueFont
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            editing = nil
            (control as? NSTextField)?.isEditable = false
            window?.makeFirstResponder(tableView)
            tableView.reloadData()
            return true
        }
        return false
    }

    public func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, let (row, c) = editing else { return }
        editing = nil
        field.isEditable = false
        let newValue = field.stringValue
        let old = dataSource?.gridValue(row: row, column: c)
        if newValue != (old ?? "") || (old == nil && !newValue.isEmpty) {
            dataSource?.gridDidEdit(row: row, column: c, value: .value(newValue))
        }
        reloadRows(IndexSet(integer: row))
        window?.makeFirstResponder(tableView)
        let movement = (obj.userInfo?["NSTextMovement"] as? Int) ?? 0
        if movement == NSTextMovement.tab.rawValue, let next = nextEditableColumn(after: c) {
            setFocusedColumn(next)
            beginEditing(row: row, column: next)
        } else if movement == NSTextMovement.return.rawValue, row + 1 < tableView.numberOfRows {
            selectRow(row + 1, column: c)
        }
    }

    private func nextEditableColumn(after c: Int) -> Int? {
        guard let ds = dataSource else { return nil }
        var i = c + 1
        while i < ds.gridColumns.count {
            if ds.gridCanEdit(column: i) { return i }
            i += 1
        }
        return nil
    }

    // MARK: Keyboard & clipboard (called by GridTableView)

    func handleKey(_ event: NSEvent) -> Bool {
        guard let ds = dataSource else { return false }
        let count = ds.gridColumns.count
        switch event.keyCode {
        case 123: // ←
            if let f = focusedColumn, f > 0 { setFocusedColumn(f - 1); return true }
            return true
        case 124: // →
            if let f = focusedColumn, f + 1 < count { setFocusedColumn(f + 1) } else if focusedColumn == nil, count > 0 { setFocusedColumn(0) }
            return true
        case 36, 76: // return
            beginEditingFocusedCell()
            return true
        case 51, 117: // delete
            if !tableView.selectedRowIndexes.isEmpty, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty || event.modifierFlags.contains(.command) {
                ds.gridDeleteRows(tableView.selectedRowIndexes)
                return true
            }
        case 48: // tab
            if let f = focusedColumn {
                let next = event.modifierFlags.contains(.shift) ? max(0, f - 1) : min(count - 1, f + 1)
                setFocusedColumn(next)
                return true
            }
        default:
            break
        }
        return false
    }

    func focusFromClick(at point: NSPoint) {
        let col = tableView.column(at: point)
        if let c = dataColumnIndex(forTableColumn: col) { setFocusedColumn(c) }
    }

    public func copySelection(asRows: Bool = false) {
        guard let ds = dataSource else { return }
        let rows = tableView.selectedRowIndexes
        guard !rows.isEmpty else { return }
        if rows.count == 1, !asRows, let c = focusedColumn {
            Pasteboard.copy(ds.gridValue(row: rows.first!, column: c) ?? "NULL")
            return
        }
        var lines: [String] = []
        for r in rows {
            lines.append((0..<ds.gridColumns.count).map { ds.gridValue(row: r, column: $0) ?? "NULL" }
                .map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
                .joined(separator: "\t"))
        }
        Pasteboard.copy(lines.joined(separator: "\n"))
    }

    func paste() {
        guard let ds = dataSource, let s = NSPasteboard.general.string(forType: .string), let c = focusedColumn, ds.gridCanEdit(column: c) else { return }
        let rows = tableView.selectedRowIndexes
        // Multi-line paste fills consecutive rows; single value fills every selected row.
        let lines = s.components(separatedBy: "\n")
        if lines.count > 1, let first = rows.first {
            for (i, line) in lines.enumerated() where first + i < ds.gridRowCount {
                let cells = line.components(separatedBy: "\t")
                for (j, v) in cells.enumerated() where c + j < ds.gridColumns.count && ds.gridCanEdit(column: c + j) {
                    ds.gridDidEdit(row: first + i, column: c + j, value: v == "NULL" ? .null : .value(v))
                }
            }
        } else {
            for r in rows { ds.gridDidEdit(row: r, column: c, value: s == "NULL" ? .null : .value(s)) }
        }
        tableView.reloadData()
    }

    func contextMenu(for event: NSEvent) -> NSMenu? {
        let p = tableView.convert(event.locationInWindow, from: nil)
        let row = tableView.row(at: p)
        guard row >= 0, let c = dataColumnIndex(forTableColumn: tableView.column(at: p)) else { return nil }
        if !tableView.isRowSelected(row) { tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        setFocusedColumn(c)
        return dataSource?.gridMenu(row: row, column: c)
    }
}

/// NSTableView that routes keys, clicks, copy and paste to its DataGridView.
@MainActor
public final class GridTableView: NSTableView {
    weak var grid: DataGridView?

    public override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        super.mouseDown(with: event)
        grid?.focusFromClick(at: p)
    }

    public override func keyDown(with event: NSEvent) {
        if grid?.handleKey(event) == true { return }
        super.keyDown(with: event)
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        grid?.contextMenu(for: event) ?? super.menu(for: event)
    }

    @objc public func copy(_ sender: Any?) { grid?.copySelection() }
    @objc public func copyRows(_ sender: Any?) { grid?.copySelection(asRows: true) }
    @objc public func paste(_ sender: Any?) { grid?.paste() }

    public override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) || item.action == #selector(copyRows(_:)) { return !selectedRowIndexes.isEmpty }
        if item.action == #selector(paste(_:)) { return !selectedRowIndexes.isEmpty }
        return super.validateUserInterfaceItem(item)
    }
}

/// Selected rows get a quiet gray band (TablePlus) instead of the saturated system highlight;
/// the focused cell keeps its accent outline.
final class GridRowView: NSTableRowView {
    static let id = NSUserInterfaceItemIdentifier("gridRow")

    convenience init() {
        self.init(frame: .zero)
        identifier = Self.id
    }

    override func drawSelection(in dirtyRect: NSRect) {
        NSColor(name: nil) { a in
            a.isDark ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 0, alpha: 0.075)
        }.setFill()
        bounds.fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

/// Column header: name in medium weight with the database type in a lighter tone.
final class GridHeaderCell: NSTableHeaderCell {
    private var typeName: String?
    private var kind: ValueKind?

    static let nameFont = NSFont.systemFont(ofSize: 12, weight: .regular)
    static let typeFont = NSFont.systemFont(ofSize: 10, weight: .regular)

    convenience init(name: String, type: String?, kind: ValueKind? = nil) {
        self.init(textCell: name)
        self.typeName = type
        self.kind = kind
    }

    /// Small glyph for the value family, like spreadsheet column headers.
    static func symbol(for kind: ValueKind) -> String {
        switch kind {
        case .text: return "textformat"
        case .integer, .decimal: return "number"
        case .boolean: return "checkmark.square"
        case .date: return "calendar"
        case .time, .interval: return "clock"
        case .timestamp: return "calendar.badge.clock"
        case .json: return "curlybraces"
        case .uuid: return "tag"
        case .binary: return "doc"
        case .array: return "list.bullet"
        case .enumeration: return "list.bullet.circle"
        case .network: return "network"
        case .geometric: return "skew"
        case .other: return "questionmark.square"
        }
    }

    static func width(name: String, type: String?) -> CGFloat {
        let n = (name as NSString).size(withAttributes: [.font: nameFont]).width
        let t = type.map { ($0 as NSString).size(withAttributes: [.font: typeFont]).width + 6 } ?? 0
        return n + t + 30
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        NSColor(name: nil) { a in a.isDark ? NSColor(white: 0.17, alpha: 1) : NSColor(srgbRed: 0.975, green: 0.975, blue: 0.98, alpha: 1) }.setFill()
        cellFrame.fill()
        NSColor.separatorColor.withAlphaComponent(0.5).setFill()
        NSRect(x: cellFrame.minX, y: cellFrame.maxY - 1, width: cellFrame.width, height: 1).fill()
        NSColor.separatorColor.withAlphaComponent(0.25).setFill()
        NSRect(x: cellFrame.maxX - 1, y: cellFrame.minY + 5, width: 1, height: cellFrame.height - 10).fill()
        drawInterior(withFrame: cellFrame, in: controlView)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        // AppKit fills the area right of the last column with a copy of a header cell whose title is cleared.
        guard !stringValue.isEmpty else { return }
        let text = NSMutableAttributedString(string: stringValue, attributes: [.font: Self.nameFont, .foregroundColor: NSColor.labelColor])
        if let typeName, !typeName.isEmpty {
            text.append(NSAttributedString(string: "  " + typeName, attributes: [.font: Self.typeFont, .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.8)]))
        }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        text.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: text.length))
        if kind == nil && (typeName ?? "").isEmpty {
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            para.lineBreakMode = .byTruncatingTail
            let t = NSAttributedString(string: stringValue, attributes: [.font: Self.nameFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: para])
            let h = t.size().height
            t.draw(in: NSRect(x: cellFrame.minX + 6, y: cellFrame.midY - h / 2, width: cellFrame.width - 12, height: h))
            return
        }
        var x = cellFrame.minX + 8
        if let kind, let img = NSImage(systemSymbolName: Self.symbol(for: kind), accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9.5, weight: .medium)) {
            let tinted = img.copy() as! NSImage
            tinted.lockFocus()
            NSColor.tertiaryLabelColor.set()
            NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
            tinted.unlockFocus()
            let size = tinted.size
            tinted.draw(in: NSRect(x: x, y: cellFrame.midY - size.height / 2, width: size.width, height: size.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += 16
        }
        let h = text.size().height
        let rect = NSRect(x: x, y: cellFrame.midY - h / 2, width: cellFrame.maxX - x - 16, height: h)
        text.draw(in: rect)
    }

    override func drawSortIndicator(withFrame cellFrame: NSRect, in controlView: NSView, ascending: Bool, priority: Int) {
        guard priority == 0 else { return }
        let img = NSImage(systemSymbolName: ascending ? "chevron.up" : "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .bold))
        img?.isTemplate = true
        let r = NSRect(x: cellFrame.maxX - 16, y: cellFrame.midY - 4, width: 9, height: 8)
        NSColor.secondaryLabelColor.set()
        img?.draw(in: r)
    }
}

/// One grid cell: single-line value, NULL placeholder, change highlight, focus ring.
@MainActor
public final class GridCellView: NSTableCellView {
    let field = NSTextField()
    var valueFont = NSFont.systemFont(ofSize: 12)

    static var baseSize: CGFloat {
        let size = UserDefaults.standard.double(forKey: "gridFontSize")
        return size > 0 ? size : 12
    }

    /// Proportional text with tabular digits; monospace only where alignment of characters matters.
    /// One monospaced face for every value, like TablePlus: columns of ids, dates and text all line up.
    static func font(for kind: ValueKind) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: baseSize, weight: .regular)
    }

    /// Very dark gray rather than pure black, which reads calmer in a dense monospaced grid.
    static let valueColor = NSColor(name: nil) { a in
        a.isDark ? NSColor(white: 0.88, alpha: 1) : NSColor(white: 0.16, alpha: 1)
    }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        wantsLayer = true
        layer?.cornerRadius = 3
        field.isBordered = false
        field.isEditable = false
        field.isSelectable = false
        field.drawsBackground = false
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.truncatesLastVisibleLine = true
        field.focusRingType = .none
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(value: String?, column: ResultColumn, state: GridCellState, nullText: String, focused: Bool) {
        valueFont = Self.font(for: column.kind)
        if let value {
            let display = value.count > 500 ? String(value.prefix(500)) + "…" : value
            field.stringValue = display.replacingOccurrences(of: "\n", with: "⏎ ").replacingOccurrences(of: "\r", with: "")
            if column.kind == .boolean {
                let on = ["true", "t", "1", "yes"].contains(value.lowercased())
                field.stringValue = on ? "TRUE" : (["false", "f", "0", "no"].contains(value.lowercased()) ? "FALSE" : value)
            }
            field.textColor = Self.valueColor
            field.font = valueFont
        } else {
            field.stringValue = nullText
            field.textColor = MTPColors.null
            field.font = NSFont.monospacedSystemFont(ofSize: Self.baseSize, weight: .regular)
        }
        field.alignment = column.isNumeric ? .right : (column.kind == .boolean ? .center : .left)
        field.toolTip = value.map { $0.count > 60 ? String($0.prefix(1000)) : nil } ?? nil
        switch state {
        case .normal: layer?.backgroundColor = nil
        case .edited: layer?.backgroundColor = MTPColors.editedCell.cgColor
        case .inserted: layer?.backgroundColor = MTPColors.insertedRow.cgColor
        case .deleted: layer?.backgroundColor = MTPColors.deletedRow.cgColor
        }
        if state == .deleted {
            field.attributedStringValue = NSAttributedString(string: field.stringValue, attributes: [
                .strikethroughStyle: NSUnderlineStyle.single.rawValue, .font: valueFont, .foregroundColor: NSColor.secondaryLabelColor,
            ])
        }
        layer?.borderWidth = focused ? 1.5 : 0
        layer?.borderColor = focused ? NSColor.controlAccentColor.cgColor : nil
    }

    func configureRowNumber(_ n: Int, state: GridCellState) {
        field.stringValue = String(n)
        field.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        field.textColor = .tertiaryLabelColor
        field.alignment = .right
        layer?.borderWidth = 0
        switch state {
        case .inserted: layer?.backgroundColor = MTPColors.insertedRow.cgColor
        case .deleted: layer?.backgroundColor = MTPColors.deletedRow.cgColor
        default: layer?.backgroundColor = nil
        }
    }
}

public extension ValueKind {
    /// SF Symbol for the value family (text, number, date…), shared by grid headers and pickers.
    var symbolName: String { GridHeaderCell.symbol(for: self) }
}
