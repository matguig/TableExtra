import Foundation

/// A value typed in the grid: an explicit value, SQL NULL, or the column DEFAULT.
public enum CellEdit: Hashable, Sendable {
    case value(String)
    case null
    case `default`

    public var stringValue: String? {
        if case .value(let s) = self { return s }
        return nil
    }
}

/// Uncommitted edits of a table data tab (TablePlus "pending changes", committed with ⌘S).
public struct ChangeSet: Sendable {
    /// row index in the loaded page → column name → new value.
    public var updates: [Int: [String: CellEdit]] = [:]
    /// Rows added with ⌘I; only edited columns are sent, others use their DEFAULT.
    public var inserts: [[String: CellEdit]] = []
    public var deletes: Set<Int> = []

    public init() {}

    public var isEmpty: Bool { updates.isEmpty && inserts.isEmpty && deletes.isEmpty }
    public var count: Int { updates.values.reduce(0) { $0 + $1.count } + inserts.count + deletes.count }

    public mutating func set(row: Int, column: String, to edit: CellEdit) {
        updates[row, default: [:]][column] = edit
    }

    public mutating func clear() { self = ChangeSet() }
}

public struct ChangeSetBuilder {
    public var schema: String
    public var table: String
    public var columns: [ColumnDef]
    /// Primary key column names; empty means rows are identified by ctid / rowid.
    public var primaryKey: [String]
    public var dialect: SQLDialect

    public init(schema: String, table: String, columns: [ColumnDef], primaryKey: [String], dialect: SQLDialect) {
        self.schema = schema
        self.table = table
        self.columns = columns
        self.primaryKey = primaryKey
        self.dialect = dialect
    }

    var qualified: String { dialect.qualified(schema: schema, name: table) }

    /// - Parameters:
    ///   - rows: loaded page; `resultColumns` gives the name of each value. When the table has
    ///     no primary key, the trailing `TableQuery.rowIDAlias` column identifies the row.
    public func statements(for changes: ChangeSet, rows: [[String?]], resultColumns: [String]) throws -> [SQLStatementWithParams] {
        var out: [SQLStatementWithParams] = []
        let index = Dictionary(resultColumns.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })

        func identity(row: Int, firstParam: Int) throws -> (String, [String?]) {
            guard row < rows.count else { throw DatabaseError("Row \(row + 1) is no longer loaded") }
            let values = rows[row]
            if primaryKey.isEmpty {
                guard let i = index[TableQuery.rowIDAlias], let rid = values[i] else {
                    throw DatabaseError("Table \(table) has no primary key; reload the tab to edit it")
                }
                return (dialect.rowIDComparison(dialect.placeholder(firstParam)), [rid])
            }
            var parts: [String] = []
            var params: [String?] = []
            for k in primaryKey {
                guard let i = index[k] else { throw DatabaseError("Primary key column \(k) is not loaded") }
                if let v = values[i] {
                    params.append(v)
                    parts.append("\(dialect.quoteIdent(k)) = \(dialect.placeholder(firstParam + params.count - 1))")
                } else {
                    parts.append("\(dialect.quoteIdent(k)) IS NULL")
                }
            }
            return (parts.joined(separator: " AND "), params)
        }

        for row in changes.updates.keys.sorted() where !changes.deletes.contains(row) {
            guard let edits = changes.updates[row], !edits.isEmpty else { continue }
            var sets: [String] = []
            var params: [String?] = []
            for name in edits.keys.sorted(by: { (ordinal($0)) < (ordinal($1)) }) {
                switch edits[name]! {
                case .value(let v):
                    params.append(v)
                    sets.append("\(dialect.quoteIdent(name)) = \(dialect.placeholder(params.count))")
                case .null:
                    sets.append("\(dialect.quoteIdent(name)) = NULL")
                case .default:
                    sets.append("\(dialect.quoteIdent(name)) = DEFAULT")
                }
            }
            let (whereSQL, whereParams) = try identity(row: row, firstParam: params.count + 1)
            out.append(SQLStatementWithParams("UPDATE \(qualified) SET \(sets.joined(separator: ", ")) WHERE \(whereSQL)", params + whereParams))
        }

        for insert in changes.inserts {
            let named = insert.filter { if case .default = $0.value { return false }; return true }
            if named.isEmpty {
                out.append(SQLStatementWithParams("INSERT INTO \(qualified) DEFAULT VALUES"))
                continue
            }
            let names = named.keys.sorted { ordinal($0) < ordinal($1) }
            var params: [String?] = []
            let values: [String] = names.map { n in
                switch named[n]! {
                case .value(let v):
                    params.append(v)
                    return dialect.placeholder(params.count)
                case .null: return "NULL"
                case .default: return "DEFAULT"
                }
            }
            out.append(SQLStatementWithParams(
                "INSERT INTO \(qualified) (\(names.map(dialect.quoteIdent).joined(separator: ", "))) VALUES (\(values.joined(separator: ", ")))",
                params))
        }

        for row in changes.deletes.sorted() {
            let (whereSQL, params) = try identity(row: row, firstParam: 1)
            out.append(SQLStatementWithParams("DELETE FROM \(qualified) WHERE \(whereSQL)", params))
        }
        return out
    }

    private func ordinal(_ name: String) -> Int { columns.firstIndex { $0.name == name } ?? Int.max }

    /// Readable SQL for the ⌘P preview sheet.
    public func preview(_ statements: [SQLStatementWithParams]) -> String {
        statements.map { SQLInterpolator.inline($0.sql, params: $0.params, dialect: dialect) + ";" }.joined(separator: "\n")
    }
}
