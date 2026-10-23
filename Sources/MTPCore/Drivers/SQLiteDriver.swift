import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class SQLiteDriver: DatabaseDriver {
    public let kind = DriverKind.sqlite
    public let dialect = SQLDialect(kind: .sqlite)

    private var db: OpaquePointer?
    private let path: String
    private let readOnly: Bool

    public init(path: String, readOnly: Bool = false) throws {
        self.path = (path as NSString).expandingTildeInPath
        self.readOnly = readOnly
        try open()
    }

    deinit { close() }

    private func open() throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, flags | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open \(path)"
            if let handle { sqlite3_close(handle) }
            throw DatabaseError(msg)
        }
        sqlite3_busy_timeout(handle, 5000)
        sqlite3_exec(handle, "PRAGMA foreign_keys = ON", nil, nil, nil)
        db = handle
    }

    public var isAlive: Bool { db != nil }

    public var inTransaction: Bool {
        guard let db else { return false }
        return sqlite3_get_autocommit(db) == 0
    }

    public func reconnect() throws {
        close()
        try open()
    }

    public func close() {
        if let db { sqlite3_close_v2(db) }
        db = nil
    }

    public func cancel() {
        if let db { sqlite3_interrupt(db) }
    }

    public func serverInfo() throws -> ServerInfo {
        ServerInfo(product: "SQLite", version: String(cString: sqlite3_libversion()), numericVersion: Int(sqlite3_libversion_number()),
                   currentDatabase: (path as NSString).lastPathComponent, currentUser: NSUserName())
    }

    public func execute(_ sql: String, params: [String?], maxRows: Int?) throws -> QueryResult {
        guard let db else { throw DatabaseError("Database is closed") }
        let start = Date()
        var result = QueryResult(statement: sql)
        let limit = maxRows.flatMap { $0 > 0 ? $0 : nil }

        try sql.withCString { base in
            var tail: UnsafePointer<CChar>? = base
            while let current = tail, current.pointee != 0 {
                var stmt: OpaquePointer?
                var next: UnsafePointer<CChar>?
                let rc = sqlite3_prepare_v2(db, current, -1, &stmt, &next)
                tail = next
                guard rc == SQLITE_OK else { throw lastError() }
                guard let stmt else { continue } // whitespace or comment only
                defer { sqlite3_finalize(stmt) }

                for (i, p) in params.enumerated() where Int32(i) < sqlite3_bind_parameter_count(stmt) {
                    if let p {
                        sqlite3_bind_text(stmt, Int32(i + 1), p, -1, SQLITE_TRANSIENT)
                    } else {
                        sqlite3_bind_null(stmt, Int32(i + 1))
                    }
                }

                let nCols = sqlite3_column_count(stmt)
                var stepResult = QueryResult(statement: sql)
                if nCols > 0 {
                    stepResult.columns = (0..<nCols).map { i in
                        let name = String(cString: sqlite3_column_name(stmt, i))
                        let decl = sqlite3_column_decltype(stmt, i).map { String(cString: $0) } ?? ""
                        return ResultColumn(name: name, typeName: decl.isEmpty ? "" : decl.uppercased(), tableColumn: Int(i))
                    }
                }
                var truncated = false
                loop: while true {
                    let s = sqlite3_step(stmt)
                    switch s {
                    case SQLITE_ROW:
                        if let limit, stepResult.rows.count >= limit {
                            truncated = true
                            break loop
                        }
                        var row: [String?] = []
                        row.reserveCapacity(Int(nCols))
                        for c in 0..<nCols { row.append(value(stmt, c)) }
                        stepResult.rows.append(row)
                    case SQLITE_DONE:
                        break loop
                    default:
                        throw lastError()
                    }
                }
                // Fill missing declared types from the first non-null value.
                if nCols > 0 {
                    for (i, col) in stepResult.columns.enumerated() where col.typeName.isEmpty {
                        let sample = stepResult.rows.first { $0[i] != nil }?[i] ?? nil
                        let inferred = sample.map { Int64($0) != nil ? "INTEGER" : (Double($0) != nil ? "REAL" : "TEXT") } ?? "TEXT"
                        stepResult.columns[i] = ResultColumn(name: col.name, typeName: inferred, tableColumn: col.tableColumn)
                    }
                    stepResult.isTruncated = truncated
                    stepResult.commandTag = "SELECT \(stepResult.rows.count)"
                } else {
                    let keyword = Self.firstKeyword(of: String(cString: sqlite3_sql(stmt)))
                    stepResult.commandTag = keyword
                    if ["INSERT", "UPDATE", "DELETE", "REPLACE"].contains(keyword) {
                        stepResult.affectedRows = Int(sqlite3_changes(db))
                        stepResult.commandTag = "\(keyword) \(sqlite3_changes(db))"
                    }
                }
                // Keep the last statement that produced rows, or else the last one.
                if stepResult.hasRows || !result.hasRows { result = stepResult }
            }
        }
        result.duration = Date().timeIntervalSince(start)
        return result
    }

    private func value(_ stmt: OpaquePointer, _ c: Int32) -> String? {
        switch sqlite3_column_type(stmt, c) {
        case SQLITE_NULL:
            return nil
        case SQLITE_INTEGER:
            return String(sqlite3_column_int64(stmt, c))
        case SQLITE_FLOAT:
            let d = sqlite3_column_double(stmt, c)
            return d.rounded() == d && abs(d) < 1e15 ? String(format: "%.1f", d) : String(d)
        case SQLITE_BLOB:
            let n = Int(sqlite3_column_bytes(stmt, c))
            guard n > 0, let p = sqlite3_column_blob(stmt, c) else { return "x''" }
            let bytes = UnsafeRawBufferPointer(start: p, count: min(n, 1 << 20))
            return "x'" + bytes.map { String(format: "%02x", $0) }.joined() + "'"
        default:
            guard let t = sqlite3_column_text(stmt, c) else { return "" }
            return String(cString: t)
        }
    }

    private func lastError() -> DatabaseError {
        guard let db else { return DatabaseError("Database is closed") }
        let code = sqlite3_errcode(db)
        let msg = String(cString: sqlite3_errmsg(db))
        return DatabaseError(msg, sqlState: code == SQLITE_INTERRUPT ? "57014" : "SQLITE_\(code)")
    }

    static func firstKeyword(of sql: String) -> String {
        let tokens = SQLTokenizer.tokenize(sql).filter { !$0.kind.isTrivia }
        return tokens.first.map { $0.text.uppercased() } ?? ""
    }
}
