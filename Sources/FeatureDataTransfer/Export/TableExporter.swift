import Foundation
import MTPCore

public struct TableExportProgress: Sendable {
    public var tableIndex: Int
    public var tableCount: Int
    public var table: String
    public var rowsInTable: Int
    public var estimatedRowsInTable: Int64?
    public var totalRows: Int

    /// 0…1 across all tables, using planner estimates for the current one.
    public var fraction: Double {
        guard tableCount > 0 else { return 0 }
        var inTable = 0.0
        if let e = estimatedRowsInTable, e > 0 { inTable = min(1, Double(rowsInTable) / Double(e)) }
        return min(1, (Double(tableIndex) + inTable) / Double(tableCount))
    }
}

public struct TableExportResult: Sendable {
    public var files: [URL]
    public var rows: Int
    public var rowsPerTable: [String: Int]
    public var duration: TimeInterval
}

/// Streams whole tables to disk page by page on a dedicated connection.
///
/// PostgreSQL reads through a server-side cursor inside a REPEATABLE READ READ ONLY transaction
/// (one consistent snapshot, constant cost per page, primary-key order).
/// SQLite pages with LIMIT/OFFSET ordered by the primary key (or rowid) inside a read transaction.
public final class TableExporter: @unchecked Sendable {
    public static let pageSize = 5_000

    public let client: DBClient
    public let pageSize: Int

    public init(client: DBClient, pageSize: Int = TableExporter.pageSize) {
        self.client = client
        self.pageSize = max(1, pageSize)
    }

    /// Where each table goes: SQL always produces one file; other formats one file per table.
    public static func outputs(tables: [String], format: ExportFormat, destination: URL) -> [String: URL] {
        if format == .sqlInsert || tables.count == 1 {
            return Dictionary(uniqueKeysWithValues: tables.map { ($0, destination) })
        }
        return Dictionary(uniqueKeysWithValues: tables.map { ($0, destination.appendingPathComponent(safeFileName($0)).appendingPathExtension(format.fileExtension)) })
    }

    static func safeFileName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>\n\r\t")
        let cleaned = s.unicodeScalars.map { bad.contains($0) ? "_" : String($0) }.joined()
        return cleaned.isEmpty ? "table" : cleaned
    }

    public func export(schema: String, tables: [String], format: ExportFormat, options: ExportOptions, destination: URL,
                       progress: @escaping @Sendable (TableExportProgress) -> Void) async throws -> TableExportResult {
        let start = Date()
        let dialect = client.dialect
        let introspector = Introspection.make(client)
        let objects = (try? await introspector.objects(in: schema)) ?? []
        let kinds = Dictionary(objects.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })

        var details: [String: TableDetails] = [:]
        for t in tables {
            details[t] = try? await introspector.tableDetails(schema: schema, name: t)
        }
        let ordered = format == .sqlInsert ? Self.dependencyOrder(tables, details: details) : tables
        let outputs = Self.outputs(tables: ordered, format: format, destination: destination)

        var written: [URL] = []
        var handles: [URL: FileHandle] = [:]
        func handle(for url: URL) throws -> FileHandle {
            if let h = handles[url] { return h }
            try? FileManager.default.removeItem(at: url)
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw DatabaseError("Cannot create \(url.path)")
            }
            let h = try FileHandle(forWritingTo: url)
            handles[url] = h
            written.append(url)
            if options.utf8BOM && (format == .csv || format == .tsv) { try h.write(contentsOf: Data([0xEF, 0xBB, 0xBF])) }
            return h
        }
        func closeAll() {
            for h in handles.values { try? h.close() }
            handles.removeAll()
        }

        var totalRows = 0
        var perTable: [String: Int] = [:]
        var transactionOpen = false
        do {
            try await withTaskCancellationHandler {
                if dialect.kind == .postgres {
                    _ = try await client.query("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY")
                } else {
                    _ = try await client.query("BEGIN")
                }
                transactionOpen = true

                if format == .sqlInsert, let url = outputs[ordered.first ?? ""] {
                    let h = try handle(for: url)
                    let stamp = ISO8601DateFormatter().string(from: Date())
                    var head = "-- TableExtra export\n-- Database: \(client.config.database.isEmpty ? client.config.filePath : client.config.database)"
                    head += dialect.kind == .postgres ? ", schema: \(schema)" : ""
                    head += "\n-- Generated: \(stamp)\n\n"
                    try h.write(contentsOf: Data(head.utf8))
                }

                for (index, table) in ordered.enumerated() {
                    try Task.checkCancellation()
                    guard let url = outputs[table] else { continue }
                    let h = try handle(for: url)
                    let object = kinds[table] ?? DBObject(schema: schema, name: table, kind: .table)
                    let estimate = await self.estimate(schema: schema, table: table, object: object)
                    var info = TableExportProgress(tableIndex: index, tableCount: ordered.count, table: table, rowsInTable: 0,
                                                   estimatedRowsInTable: estimate, totalRows: totalRows)
                    progress(info)

                    if format == .sqlInsert {
                        var pre = "-- Table: \(object.qualifiedName)\n"
                        if options.includeCreateTable && object.kind == .table {
                            if options.includeDropTable {
                                pre += "DROP TABLE IF EXISTS \(dialect.qualified(schema: schema, name: table));\n"
                            }
                            let ddl = (try? await introspector.ddl(for: object)) ?? ""
                            if !ddl.isEmpty { pre += ddl + "\n" }
                        }
                        try h.write(contentsOf: Data((pre + "\n").utf8))
                    }

                    let pk = details[table]?.primaryKey ?? []
                    var encoder: ExportEncoder?
                    try await self.forEachPage(schema: schema, table: table, primaryKey: pk, isTable: object.kind == .table) { page in
                        if encoder == nil {
                            var e = ExportEncoder(format: format, columns: page.columns, options: options, tableName: table, schema: schema, dialect: dialect)
                            try h.write(contentsOf: Data(e.header().utf8))
                            encoder = e
                        }
                        let chunk = encoder!.encode(page.rows)
                        if !chunk.isEmpty { try h.write(contentsOf: Data(chunk.utf8)) }
                        info.rowsInTable += page.rows.count
                        totalRows += page.rows.count
                        info.totalRows = totalRows
                        progress(info)
                    }
                    if let e = encoder {
                        let tail = e.footer() + (format == .sqlInsert ? "\n" : "")
                        if !tail.isEmpty { try h.write(contentsOf: Data(tail.utf8)) }
                    }
                    perTable[table] = info.rowsInTable
                    // Table done: index moves on, no partial share left for this table.
                    progress(TableExportProgress(tableIndex: index + 1, tableCount: ordered.count, table: table, rowsInTable: info.rowsInTable,
                                                 estimatedRowsInTable: nil, totalRows: totalRows))
                }
                _ = try await client.query("COMMIT")
                transactionOpen = false
            } onCancel: {
                self.client.cancel()
            }
        } catch {
            closeAll()
            if transactionOpen { _ = try? await client.query("ROLLBACK") }
            for url in written { try? FileManager.default.removeItem(at: url) }
            if Task.isCancelled || (error as? DatabaseError)?.isCancellation == true { throw CancellationError() }
            throw error
        }
        closeAll()
        return TableExportResult(files: written, rows: totalRows, rowsPerTable: perTable, duration: Date().timeIntervalSince(start))
    }

    private func estimate(schema: String, table: String, object: DBObject) async -> Int64? {
        if client.dialect.kind == .postgres {
            if let e = object.estimatedRows, e > 0 { return e }
            let q = client.dialect.qualified(schema: schema, name: table)
            if let r = try? await client.query("SELECT reltuples::bigint FROM pg_class WHERE oid = $1::regclass", [q]),
               let v = r.rows.first?[0].flatMap({ Int64($0) }), v > 0 { return v }
            return nil
        }
        let q = client.dialect.qualified(schema: schema, name: table)
        let r = try? await client.query("SELECT count(*) FROM \(q)")
        return r?.rows.first?[0].flatMap { Int64($0) }
    }

    /// Calls `body` with each page; the first call always happens, even for an empty table, so columns are known.
    func forEachPage(schema: String, table: String, primaryKey: [String], isTable: Bool,
                     body: (QueryResult) throws -> Void) async throws {
        let dialect = client.dialect
        let source = dialect.qualified(schema: schema, name: table)
        var order = ""
        if !primaryKey.isEmpty {
            order = " ORDER BY " + primaryKey.map(dialect.quoteIdent).joined(separator: ", ")
        } else if dialect.kind == .sqlite && isTable {
            order = " ORDER BY rowid"
        }

        if dialect.kind == .postgres {
            let cursor = "mtp_export_cursor"
            _ = try await client.query("DECLARE \(cursor) NO SCROLL CURSOR FOR SELECT * FROM \(source)\(order)")
            var first = true
            while true {
                try Task.checkCancellation()
                let page = try await client.query("FETCH FORWARD \(pageSize) FROM \(cursor)")
                if first || !page.rows.isEmpty { try body(page) }
                first = false
                if page.rows.count < pageSize { break }
            }
            _ = try await client.query("CLOSE \(cursor)")
        } else {
            var offset = 0
            while true {
                try Task.checkCancellation()
                let page = try await client.query("SELECT * FROM \(source)\(order) LIMIT \(pageSize) OFFSET \(offset)")
                if offset == 0 || !page.rows.isEmpty { try body(page) }
                if page.rows.count < pageSize { break }
                offset += page.rows.count
            }
        }
    }

    /// Referenced tables first so the generated SQL replays without foreign-key errors.
    static func dependencyOrder(_ tables: [String], details: [String: TableDetails]) -> [String] {
        let set = Set(tables)
        var visited: Set<String> = []
        var visiting: Set<String> = []
        var out: [String] = []
        func visit(_ t: String) {
            if visited.contains(t) || visiting.contains(t) { return }
            visiting.insert(t)
            for fk in details[t]?.foreignKeys ?? [] where set.contains(fk.refTable) && fk.refTable != t {
                visit(fk.refTable)
            }
            visiting.remove(t)
            visited.insert(t)
            out.append(t)
        }
        tables.forEach(visit)
        return out
    }
}
