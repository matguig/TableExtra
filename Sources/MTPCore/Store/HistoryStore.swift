import Foundation

public struct HistoryEntry: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var connectionID: UUID?
    public var database: String
    public var sql: String
    public var executedAt: Date
    public var duration: TimeInterval
    public var rowCount: Int?
    public var error: String?
    /// "editor", "data", "mcp", "ai", "tableplus"...
    public var source: String
}

/// Every executed statement, kept in a local SQLite database with full-text-ish search.
public final class HistoryStore: @unchecked Sendable {
    public static let shared = HistoryStore()

    private let queue = DispatchQueue(label: "mtp.history")
    private var driver: SQLiteDriver?

    public init(url: URL = AppPaths.historyDatabase) {
        queue.sync {
            driver = try? SQLiteDriver(path: url.path)
            _ = try? driver?.execute("""
            CREATE TABLE IF NOT EXISTS history (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              connection_id TEXT,
              database TEXT NOT NULL DEFAULT '',
              sql TEXT NOT NULL,
              executed_at REAL NOT NULL,
              duration REAL NOT NULL DEFAULT 0,
              row_count INTEGER,
              error TEXT,
              source TEXT NOT NULL DEFAULT 'editor'
            );
            CREATE INDEX IF NOT EXISTS history_conn_time ON history(connection_id, executed_at DESC);
            CREATE UNIQUE INDEX IF NOT EXISTS history_dedupe ON history(connection_id, executed_at, sql);
            """, params: [], maxRows: nil)
        }
    }

    public func add(connectionID: UUID?, database: String, sql: String, duration: TimeInterval, rowCount: Int?, error: String?,
                    source: String = "editor", at date: Date = Date()) {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        queue.async {
            _ = try? self.driver?.execute(
                "INSERT OR IGNORE INTO history (connection_id, database, sql, executed_at, duration, row_count, error, source) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                params: [connectionID?.uuidString, database, trimmed, String(date.timeIntervalSince1970), String(duration),
                         rowCount.map(String.init), error, source],
                maxRows: nil)
        }
    }

    public func entries(connectionID: UUID? = nil, search: String = "", limit: Int = 500) -> [HistoryEntry] {
        queue.sync {
            var sql = "SELECT id, connection_id, database, sql, executed_at, duration, row_count, error, source FROM history WHERE 1=1"
            var params: [String?] = []
            if let connectionID {
                params.append(connectionID.uuidString)
                sql += " AND connection_id = ?\(params.count)"
            }
            let words = search.split(separator: " ").map(String.init)
            for w in words {
                params.append("%\(w)%")
                sql += " AND sql LIKE ?\(params.count)"
            }
            sql += " ORDER BY executed_at DESC LIMIT \(limit)"
            guard let r = try? driver?.execute(sql, params: params, maxRows: nil) else { return [] }
            return r.rows.map { row in
                HistoryEntry(id: Int64(row[0] ?? "0") ?? 0,
                             connectionID: row[1].flatMap(UUID.init(uuidString:)),
                             database: row[2] ?? "",
                             sql: row[3] ?? "",
                             executedAt: Date(timeIntervalSince1970: Double(row[4] ?? "0") ?? 0),
                             duration: Double(row[5] ?? "0") ?? 0,
                             rowCount: row[6].flatMap { Int($0) },
                             error: row[7],
                             source: row[8] ?? "editor")
            }
        }
    }

    public func delete(_ id: Int64) {
        queue.async { _ = try? self.driver?.execute("DELETE FROM history WHERE id = ?1", params: [String(id)], maxRows: nil) }
    }

    public func clear(connectionID: UUID?) {
        queue.async {
            if let connectionID {
                _ = try? self.driver?.execute("DELETE FROM history WHERE connection_id = ?1", params: [connectionID.uuidString], maxRows: nil)
            } else {
                _ = try? self.driver?.execute("DELETE FROM history", params: [], maxRows: nil)
            }
        }
    }

    /// Waits for queued writes (tests, importer).
    public func flush() { queue.sync {} }
}
