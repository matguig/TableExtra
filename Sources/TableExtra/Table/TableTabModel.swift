import AppKit
import FeatureDataTransfer
import MTPCore
import MTPUIKit
import Observation

enum TableTabMode: String {
    case data, structure
}

@MainActor
@Observable
final class TableTabModel: WorkspaceTab, DataGridDataSource {
    let id = UUID()
    @ObservationIgnored unowned let workspace: WorkspaceModel
    var object: DBObject
    var mode: TableTabMode
    var isPreview = true

    var details: TableDetails?
    var columns: [ResultColumn] = []
    var rows: [[String?]] = []
    /// Hidden ctid/rowid values when the table has no primary key.
    var rowIDs: [String?] = []
    var filters: [FilterRule] = []
    var showFilters = false
    var matchAll = true
    /// Conditions that actually constrain the query (enabled, and with a value when one is needed).
    var activeFilters: [FilterRule] {
        filters.filter { $0.isEnabled && (!$0.op.needsValue || !$0.value.isEmpty) }
    }
    var sort: [SortKey] = []
    var pageSize: Int
    var offset = 0
    var totalCount: Int64?
    var countIsEstimate = false
    var changes = ChangeSet()
    var isLoading = false
    var errorMessage: String?
    var lastDuration: TimeInterval = 0
    var lastSQL = ""
    var selectedRows = IndexSet()
    var focusedColumn: Int?
    /// Bumped whenever the grid must reload.
    var dataVersion = 0
    var editingValue: ValueEditRequest?
    var exportRequest: ExportSource?

    struct ValueEditRequest: Identifiable {
        let id = UUID()
        var row: Int
        var column: Int
        var value: String?
        var columnName: String
        var typeName: String
        var isJSON: Bool
        var readOnly: Bool
    }

    init(workspace: WorkspaceModel, object: DBObject, mode: TableTabMode = .data) {
        self.workspace = workspace
        self.object = object
        self.mode = mode
        self.pageSize = workspace.connection.pageSize ?? AppSettings.pageSize
    }

    var title: String { object.name }
    var icon: String { object.kind.symbolName }
    var hasUnsavedChanges: Bool { !changes.isEmpty }
    var dialect: SQLDialect { workspace.dialect }
    var client: DBClient { workspace.client }

    var primaryKey: [String] { details?.primaryKey ?? [] }
    var usesRowID: Bool { primaryKey.isEmpty && object.kind == .table }
    var isEditable: Bool {
        object.kind == .table && workspace.connection.safety != .readOnly && (!primaryKey.isEmpty || usesRowID)
    }

    // MARK: Loading

    func reloadAll() async {
        do {
            details = try await workspace.introspector.tableDetails(schema: object.schema, name: object.name)
            if let est = details?.object.estimatedRows { object.estimatedRows = est }
            if !(details?.primaryKey.isEmpty ?? true) { Task { await loadReferencingForeignKeys() } }
        } catch {
            errorMessage = (error as? DatabaseError)?.fullMessage ?? error.localizedDescription
        }
        await loadPage()
    }

    private func makeQuery() -> TableQuery {
        TableQuery(schema: object.schema, table: object.name, columns: details?.columns ?? [], filters: filters, matchAll: matchAll,
                   sort: sort, limit: pageSize, offset: offset, includeRowID: usesRowID, dialect: dialect)
    }

    func loadPage() async {
        isLoading = true
        errorMessage = nil
        let q = makeQuery()
        let statement = q.selectSQL()
        lastSQL = q.displaySQL()
        do {
            let r = try await client.query(statement)
            if usesRowID, r.columns.last?.name == TableQuery.rowIDAlias {
                columns = Array(r.columns.dropLast())
                rowIDs = r.rows.map { $0.last ?? nil }
                rows = r.rows.map { Array($0.dropLast()) }
            } else {
                columns = r.columns
                rows = r.rows
                rowIDs = []
            }
            lastDuration = r.duration
            workspace.log(sql: lastSQL, duration: r.duration, outcome: r.summary, isError: false, source: "data")
            changes.clear()
            selectedRows = []
            dataVersion += 1
            isLoading = false
            await refreshCount()
        } catch {
            isLoading = false
            errorMessage = (error as? DatabaseError)?.fullMessage ?? error.localizedDescription
            workspace.log(sql: lastSQL, duration: 0, outcome: errorMessage ?? "", isError: true, source: "data")
            dataVersion += 1
        }
    }

    /// Exact counts on small tables, planner estimates on big unfiltered ones (TablePlus "estimated" mode).
    func refreshCount(forceExact: Bool = false) async {
        let threshold = Int64(UserDefaults.standard.integer(forKey: SettingKey.estimateCountThreshold))
        let activeFilters = filters.contains { $0.isEnabled }
        if !forceExact, !activeFilters, let est = object.estimatedRows, est > threshold, workspace.connection.driver == .postgres {
            totalCount = est
            countIsEstimate = true
            return
        }
        if offset == 0 && rows.count < pageSize {
            totalCount = Int64(rows.count)
            countIsEstimate = false
            return
        }
        do {
            let r = try await client.query(makeQuery().countSQL())
            totalCount = Int64(r.rows.first?[0] ?? "") ?? nil
            countIsEstimate = false
        } catch {
            totalCount = nil
        }
    }

    func applyFilters() async {
        offset = 0
        await loadPage()
    }

    func nextPage() async {
        guard rows.count >= pageSize else { return }
        if hasUnsavedChanges, !workspace.confirmDiscard() { return }
        offset += pageSize
        await loadPage()
    }

    func previousPage() async {
        guard offset > 0 else { return }
        if hasUnsavedChanges, !workspace.confirmDiscard() { return }
        offset = max(0, offset - pageSize)
        await loadPage()
    }

    func goToPage(_ page: Int) async {
        offset = max(0, (page - 1) * pageSize)
        await loadPage()
    }

    var pageNumber: Int { offset / max(1, pageSize) + 1 }
    var pageCount: Int? { totalCount.map { max(1, Int(($0 + Int64(pageSize) - 1) / Int64(pageSize))) } }

    // MARK: Editing

    var displayRowCount: Int { rows.count + changes.inserts.count }

    func value(row: Int, column: Int) -> String? {
        guard column < columns.count else { return nil }
        let name = columns[column].name
        if row >= rows.count {
            let j = row - rows.count
            guard j < changes.inserts.count else { return nil }
            switch changes.inserts[j][name] {
            case .value(let v): return v
            case .null: return nil
            case .default, .none:
                return details?.columns.first { $0.name == name }?.hasServerDefault == true ? "DEFAULT" : nil
            }
        }
        if let edit = changes.updates[row]?[name] {
            switch edit {
            case .value(let v): return v
            case .null: return nil
            case .default: return "DEFAULT"
            }
        }
        return row < rows.count && column < rows[row].count ? rows[row][column] : nil
    }

    func setValue(_ edit: CellEdit, row: Int, column: Int) {
        guard isEditable, column < columns.count else { return }
        let name = columns[column].name
        if row >= rows.count {
            let j = row - rows.count
            guard j < changes.inserts.count else { return }
            changes.inserts[j][name] = edit
        } else {
            let original = rows[row][column]
            if case .value(let v) = edit, v == original {
                changes.updates[row]?[name] = nil
            } else if case .null = edit, original == nil {
                changes.updates[row]?[name] = nil
            } else {
                changes.set(row: row, column: name, to: edit)
            }
            if changes.updates[row]?.isEmpty == true { changes.updates[row] = nil }
        }
        dataVersion += 1
    }

    func addRow() {
        guard isEditable else { NSSound.beep(); return }
        changes.inserts.append([:])
        dataVersion += 1
        selectedRows = IndexSet(integer: displayRowCount - 1)
    }

    func duplicateRows(_ indexes: IndexSet) {
        guard isEditable else { NSSound.beep(); return }
        let pk = Set(primaryKey)
        for r in indexes {
            var insert: [String: CellEdit] = [:]
            for (c, col) in columns.enumerated() {
                let def = details?.columns.first { $0.name == col.name }
                // Leave identity / serial / generated keys to the server.
                if pk.contains(col.name) && def?.hasServerDefault == true { continue }
                if def?.isGenerated == true { continue }
                insert[col.name] = value(row: r, column: c).map { .value($0) } ?? .null
            }
            changes.inserts.append(insert)
        }
        dataVersion += 1
    }

    func deleteRows(_ indexes: IndexSet) {
        guard isEditable else { NSSound.beep(); return }
        var removeInserts = IndexSet()
        for r in indexes {
            if r >= rows.count { removeInserts.insert(r - rows.count) }
            else if changes.deletes.contains(r) { changes.deletes.remove(r) }
            else { changes.deletes.insert(r) }
        }
        for j in removeInserts.reversed() where j < changes.inserts.count { changes.inserts.remove(at: j) }
        dataVersion += 1
    }

    func discard() {
        changes.clear()
        dataVersion += 1
    }

    func pendingStatements() throws -> [SQLStatementWithParams] {
        guard let details else { return [] }
        let builder = ChangeSetBuilder(schema: object.schema, table: object.name, columns: details.columns, primaryKey: primaryKey, dialect: dialect)
        var pageRows = rows
        var names = columns.map(\.name)
        if usesRowID {
            pageRows = zip(rows, rowIDs).map { $0 + [$1] }
            names.append(TableQuery.rowIDAlias)
        }
        return try builder.statements(for: changes, rows: pageRows, resultColumns: names)
    }

    func previewSQL() -> String {
        guard let details else { return "" }
        let builder = ChangeSetBuilder(schema: object.schema, table: object.name, columns: details.columns, primaryKey: primaryKey, dialect: dialect)
        do { return builder.preview(try pendingStatements()) } catch { return "-- \(error.localizedDescription)" }
    }

    func commit() async {
        guard !changes.isEmpty else { return }
        do {
            let statements = try pendingStatements()
            let preview = previewSQL()
            let summary = "\(changes.updates.count) updated, \(changes.inserts.count) inserted, \(changes.deletes.count) deleted row(s) in \(object.qualifiedName)."
            guard await workspace.confirmWrite(statements: statements.map { SQLInterpolator.inline($0.sql, params: $0.params, dialect: dialect) },
                                               summary: summary, rehearseOn: nil) else { return }
            let started = Date()
            try await client.transaction(statements)
            workspace.log(sql: preview, duration: Date().timeIntervalSince(started), outcome: summary, isError: false, source: "data")
            workspace.showToast("Committed — \(summary)")
            await loadPage()
        } catch {
            workspace.log(sql: previewSQL(), duration: 0, outcome: error.localizedDescription, isError: true, source: "data")
            workspace.showError(error)
        }
    }

    // MARK: DataGridDataSource

    var gridColumns: [ResultColumn] { columns }
    var gridRowCount: Int { displayRowCount }

    func gridValue(row: Int, column: Int) -> String? { value(row: row, column: column) }

    func gridCellState(row: Int, column: Int) -> GridCellState {
        if row >= rows.count { return .inserted }
        if changes.deletes.contains(row) { return .deleted }
        if column >= 0, column < columns.count, changes.updates[row]?[columns[column].name] != nil { return .edited }
        return .normal
    }

    func gridCanEdit(column: Int) -> Bool {
        guard isEditable, column < columns.count else { return false }
        return details?.columns.first { $0.name == columns[column].name }?.isGenerated != true
    }

    func gridDidEdit(row: Int, column: Int, value: CellEdit) { setValue(value, row: row, column: column) }
    func gridDeleteRows(_ rows: IndexSet) { deleteRows(rows) }

    func gridSortChanged(_ keys: [SortKey]) {
        sort = keys
        Task { await applyFilters() }
    }

    func gridSelectionChanged(rows: IndexSet, column: Int?) {
        selectedRows = rows
        focusedColumn = column
    }

    func gridOpenEditor(row: Int, column: Int) {
        guard column < columns.count else { return }
        let col = columns[column]
        editingValue = ValueEditRequest(row: row, column: column, value: value(row: row, column: column), columnName: col.name,
                                        typeName: col.typeName, isJSON: col.kind == .json, readOnly: !gridCanEdit(column: column))
    }

    func gridMenu(row: Int, column: Int) -> NSMenu? {
        let menu = NSMenu()
        guard column < columns.count else { return nil }
        let col = columns[column]
        let v = value(row: row, column: column)
        let editable = gridCanEdit(column: column)
        let def = details?.columns.first { $0.name == col.name }

        menu.addItem(ClosureMenuItem("Edit Value…") { [weak self] in self?.gridOpenEditor(row: row, column: column) })
        if editable {
            menu.addItem(ClosureMenuItem("Set NULL", enabled: def?.isNullable ?? true) { [weak self] in self?.setValue(.null, row: row, column: column) })
            menu.addItem(ClosureMenuItem("Set Empty String") { [weak self] in self?.setValue(.value(""), row: row, column: column) })
            if def?.hasServerDefault == true || def?.defaultValue != nil {
                menu.addItem(ClosureMenuItem("Set DEFAULT") { [weak self] in self?.setValue(.default, row: row, column: column) })
            }
            if let values = def?.enumValues, !values.isEmpty {
                let item = NSMenuItem(title: "Set Value", action: nil, keyEquivalent: "")
                let sub = NSMenu()
                for e in values { sub.addItem(ClosureMenuItem(e) { [weak self] in self?.setValue(.value(e), row: row, column: column) }) }
                item.submenu = sub
                menu.addItem(item)
            }
            if col.kind == .boolean {
                menu.addItem(ClosureMenuItem("Set true") { [weak self] in self?.setValue(.value("true"), row: row, column: column) })
                menu.addItem(ClosureMenuItem("Set false") { [weak self] in self?.setValue(.value("false"), row: row, column: column) })
            }
            if col.kind == .timestamp || col.kind == .date {
                menu.addItem(ClosureMenuItem("Set Now") { [weak self] in
                    let f = ISO8601DateFormatter()
                    f.formatOptions = col.kind == .date ? [.withFullDate] : [.withInternetDateTime, .withFractionalSeconds]
                    self?.setValue(.value(f.string(from: Date())), row: row, column: column)
                })
            }
            if changes.updates[row]?[col.name] != nil {
                menu.addItem(ClosureMenuItem("Revert Cell") { [weak self] in
                    self?.changes.updates[row]?[col.name] = nil
                    if self?.changes.updates[row]?.isEmpty == true { self?.changes.updates[row] = nil }
                    self?.dataVersion += 1
                })
            }
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Copy Value") { Pasteboard.copy(v ?? "NULL") })
        menu.addItem(ClosureMenuItem("Copy Column Name") { Pasteboard.copy(col.name) })
        let copyAs = NSMenuItem(title: "Copy Rows As", action: nil, keyEquivalent: "")
        let copyMenu = NSMenu()
        for f in ExportFormat.allCases {
            copyMenu.addItem(ClosureMenuItem(f.rawValue) { [weak self] in self?.copySelection(as: f) })
        }
        copyAs.submenu = copyMenu
        menu.addItem(copyAs)
        menu.addItem(.separator())

        let filterItem = NSMenuItem(title: "Quick Filter", action: nil, keyEquivalent: "")
        let fm = NSMenu()
        fm.addItem(ClosureMenuItem(v == nil ? "\(col.name) IS NULL" : "\(col.name) = \(v!.prefix(40))") { [weak self] in
            self?.addQuickFilter(FilterRule(column: col.name, op: v == nil ? .isNull : .equals, value: v ?? ""))
        })
        if let v {
            fm.addItem(ClosureMenuItem("\(col.name) <> \(v.prefix(40))") { [weak self] in self?.addQuickFilter(FilterRule(column: col.name, op: .notEquals, value: v)) })
            fm.addItem(ClosureMenuItem("\(col.name) contains \(v.prefix(40))") { [weak self] in self?.addQuickFilter(FilterRule(column: col.name, op: .containsCaseInsensitive, value: v)) })
        }
        filterItem.submenu = fm
        menu.addItem(filterItem)

        if let fk = def?.foreignKey, let v {
            let refCol = fk.refColumns.first ?? "id"
            menu.addItem(ClosureMenuItem("Open \(fk.refTable) where \(refCol) = \(v.prefix(30))") { [weak self] in
                self?.workspace.openTable(schema: fk.refSchema, name: fk.refTable, filter: FilterRule(column: refCol, op: .equals, value: v))
            })
        }
        if def?.isPrimaryKey == true, let v {
            let referencing = referencingForeignKeys()
            if !referencing.isEmpty {
                let item = NSMenuItem(title: "Show Referencing Rows", action: nil, keyEquivalent: "")
                let sub = NSMenu()
                for (table, fk) in referencing {
                    sub.addItem(ClosureMenuItem("\(table.object.name).\(fk.columns.first ?? "")") { [weak self] in
                        self?.workspace.openTable(schema: table.object.schema, name: table.object.name,
                                                  filter: FilterRule(column: fk.columns.first ?? "", op: .equals, value: v))
                    })
                }
                item.submenu = sub
                menu.addItem(item)
            }
        }
        if isEditable {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Duplicate Row") { [weak self] in self?.duplicateRows(self?.selectedRows ?? IndexSet(integer: row)) })
            menu.addItem(ClosureMenuItem(changes.deletes.contains(row) ? "Undelete Row" : "Delete Row") { [weak self] in
                self?.deleteRows(self?.selectedRows.isEmpty == false ? self!.selectedRows : IndexSet(integer: row))
            })
        }
        return menu
    }

    /// Foreign keys in other loaded tables of the schema that point at this table.
    @ObservationIgnored var referencingCache: [(TableDetails, ForeignKeyRef)]?

    private func referencingForeignKeys() -> [(TableDetails, ForeignKeyRef)] { referencingCache ?? [] }

    private func loadReferencingForeignKeys() async {
        guard referencingCache == nil, let snap = try? await workspace.introspector.snapshot(schema: object.schema) else { return }
        referencingCache = snap.flatMap { t in t.foreignKeys.filter { $0.refTable == object.name && $0.refSchema == object.schema }.map { (t, $0) } }
    }

    func addQuickFilter(_ rule: FilterRule) {
        filters.removeAll { $0.value.isEmpty && $0.op.needsValue }
        filters.append(rule)
        showFilters = true
        Task { await applyFilters() }
    }

    func selectedResult() -> QueryResult {
        let indexes = selectedRows.isEmpty ? IndexSet(integersIn: 0..<displayRowCount) : selectedRows
        let data = indexes.filter { $0 < displayRowCount }.map { r in (0..<columns.count).map { value(row: r, column: $0) } }
        return QueryResult(columns: columns, rows: data, statement: lastSQL)
    }

    func copySelection(as format: ExportFormat) {
        Pasteboard.copy(DataExporter.render(selectedResult(), format: format, tableName: object.name, dialect: dialect))
    }
}
