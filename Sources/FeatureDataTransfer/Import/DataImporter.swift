import Foundation
import MTPCore

/// One file column and where it goes.
public struct ImportColumn: Identifiable, Hashable, Sendable {
    public var id: Int { sourceIndex }
    public var sourceIndex: Int
    public var sourceName: String
    public var inferred: InferredType
    public var include: Bool
    /// Target column (existing table) or column to create (new table).
    public var target: String
    /// New table: SQL type to create. Existing table: the column's declared type (display only).
    public var sqlType: String
    public var targetKind: ValueKind

    public init(sourceIndex: Int, sourceName: String, inferred: InferredType, include: Bool = true, target: String, sqlType: String, targetKind: ValueKind) {
        self.sourceIndex = sourceIndex
        self.sourceName = sourceName
        self.inferred = inferred
        self.include = include
        self.target = target
        self.sqlType = sqlType
        self.targetKind = targetKind
    }
}

public struct ImportPlan: Sendable {
    public enum ErrorPolicy: String, CaseIterable, Identifiable, Sendable {
        case stop = "Stop at the first error"
        case skip = "Skip bad rows"
        public var id: String { rawValue }
    }

    public var schema: String
    public var table: String
    public var createTable: Bool
    public var columns: [ImportColumn]
    public var truncateFirst: Bool
    public var batchSize: Int
    public var errorPolicy: ErrorPolicy
    /// Unquoted empty fields become NULL (non-text columns always get NULL for empty values).
    public var emptyAsNull: Bool
    /// Unquoted values read as NULL.
    public var nullMarkers: Set<String>

    public init(schema: String, table: String, createTable: Bool = false, columns: [ImportColumn], truncateFirst: Bool = false, batchSize: Int = 500,
                errorPolicy: ErrorPolicy = .stop, emptyAsNull: Bool = true, nullMarkers: Set<String> = ["NULL", "\\N"]) {
        self.schema = schema
        self.table = table
        self.createTable = createTable
        self.columns = columns
        self.truncateFirst = truncateFirst
        self.batchSize = batchSize
        self.errorPolicy = errorPolicy
        self.emptyAsNull = emptyAsNull
        self.nullMarkers = nullMarkers
    }

    public var included: [ImportColumn] { columns.filter { $0.include && !$0.target.isEmpty } }

    public func qualifiedTable(_ d: SQLDialect) -> String { d.qualified(schema: schema, name: table) }

    public func createTableSQL(_ d: SQLDialect) -> String {
        let defs = included.map { "  \(d.quoteIdent($0.target)) \($0.sqlType)" }.joined(separator: ",\n")
        return "CREATE TABLE \(qualifiedTable(d)) (\n\(defs)\n)"
    }

    public func truncateSQL(_ d: SQLDialect) -> String {
        d.kind == .postgres ? "TRUNCATE TABLE \(qualifiedTable(d))" : "DELETE FROM \(qualifiedTable(d))"
    }

    /// Rows per INSERT, bounded by the driver's bind-parameter limit.
    public func rowsPerStatement(_ d: SQLDialect) -> Int {
        let maxParams = d.kind == .postgres ? 65_535 : 32_766
        return max(1, min(max(1, batchSize), maxParams / max(1, included.count)))
    }

    public func insertSQL(rows: Int, _ d: SQLDialect) -> String {
        let cols = included
        var sql = "INSERT INTO \(qualifiedTable(d)) (\(cols.map { d.quoteIdent($0.target) }.joined(separator: ", "))) VALUES "
        var n = 0
        for r in 0..<rows {
            if r > 0 { sql += ", " }
            sql += "("
            for c in cols.indices {
                n += 1
                if c > 0 { sql += ", " }
                sql += d.placeholder(n)
            }
            sql += ")"
        }
        return sql
    }

    /// The statements shown when asking the user to confirm.
    public func previewSQL(_ d: SQLDialect, rowCount: Int?) -> String {
        var parts: [String] = []
        if createTable { parts.append(createTableSQL(d) + ";") }
        if truncateFirst && !createTable { parts.append(truncateSQL(d) + ";") }
        let count = rowCount.map { "\($0) rows" } ?? "all rows"
        parts.append("-- \(count) in batches of \(rowsPerStatement(d))\n" + insertSQL(rows: 1, d) + ";")
        return parts.joined(separator: "\n\n")
    }

    static let textualKinds: Set<ValueKind> = [.text, .other]

    public func parameters(for row: ImportRow, dialect: SQLDialect) -> [String?] {
        included.map { value(row, $0, dialect: dialect) }
    }

    func value(_ row: ImportRow, _ col: ImportColumn, dialect: SQLDialect) -> String? {
        let i = col.sourceIndex
        guard i < row.values.count, let v = row.values[i] else { return nil }
        let quoted = i < row.quoted.count && row.quoted[i]
        if !quoted && nullMarkers.contains(v) { return nil }
        if v.isEmpty {
            if !Self.textualKinds.contains(col.targetKind) { return nil }
            return (!quoted && emptyAsNull) ? nil : ""
        }
        if dialect.kind == .sqlite && col.targetKind == .boolean {
            switch v.lowercased() {
            case "true", "t", "yes", "y", "on": return "1"
            case "false", "f", "no", "n", "off": return "0"
            default: break
            }
        }
        return v
    }
}

public struct ImportProgress: Sendable {
    public var rowsRead: Int
    public var inserted: Int
    public var skipped: Int
    public var fraction: Double
}

public struct ImportRowError: Sendable, Identifiable, Hashable {
    public var id: Int { line }
    public var line: Int
    public var message: String
}

public struct ImportReport: Sendable {
    public var inserted = 0
    public var skipped = 0
    public var errors: [ImportRowError] = []
    public var duration: TimeInterval = 0
    public var cancelled = false
    /// Set when the import was rolled back because of an error.
    public var failure: String?
    public var committed = false

    public init() {}
}

/// Batched, parameterised multi-row INSERTs in one transaction on a dedicated connection.
/// Each batch runs under a savepoint; when it fails, its rows are retried one by one to find the bad lines,
/// which either abort everything (stop) or are skipped and reported (skip).
public enum DataImporter {
    struct Stop: Error {
        var line: Int
        var message: String
    }

    public static func run(plan: ImportPlan, source: ImportRowSource, client: DBClient,
                           progress: @escaping @Sendable (ImportProgress) -> Void) async -> ImportReport {
        var report = ImportReport()
        let start = Date()
        let dialect = client.dialect
        guard !plan.included.isEmpty else {
            report.failure = "No column is mapped"
            return report
        }
        let perStatement = plan.rowsPerStatement(dialect)
        var inTransaction = false
        var rowsRead = 0
        var inserted = 0
        var skipped = 0
        var errors: [ImportRowError] = []

        func describe(_ error: Error) -> String {
            (error as? DatabaseError)?.fullMessage ?? error.localizedDescription
        }
        func isCancel(_ error: Error) -> Bool {
            error is CancellationError || (error as? DatabaseError)?.isCancellation == true
        }

        do {
            try await withTaskCancellationHandler {
                _ = try await client.query("BEGIN")
                inTransaction = true
                if plan.createTable { _ = try await client.query(plan.createTableSQL(dialect)) }
                if plan.truncateFirst && !plan.createTable { _ = try await client.query(plan.truncateSQL(dialect)) }

                while true {
                    try Task.checkCancellation()
                    let rows = try source.next(perStatement)
                    if rows.isEmpty { break }
                    rowsRead += rows.count
                    let params = rows.flatMap { plan.parameters(for: $0, dialect: dialect) }
                    do {
                        _ = try await client.query("SAVEPOINT mtp_import")
                        _ = try await client.query(plan.insertSQL(rows: rows.count, dialect), params)
                        _ = try await client.query("RELEASE SAVEPOINT mtp_import")
                        inserted += rows.count
                    } catch where !isCancel(error) {
                        _ = try await client.query("ROLLBACK TO SAVEPOINT mtp_import")
                        let single = plan.insertSQL(rows: 1, dialect)
                        for row in rows {
                            try Task.checkCancellation()
                            do {
                                _ = try await client.query("SAVEPOINT mtp_row")
                                _ = try await client.query(single, plan.parameters(for: row, dialect: dialect))
                                _ = try await client.query("RELEASE SAVEPOINT mtp_row")
                                inserted += 1
                            } catch where !isCancel(error) {
                                _ = try await client.query("ROLLBACK TO SAVEPOINT mtp_row")
                                let e = ImportRowError(line: row.line, message: describe(error))
                                if plan.errorPolicy == .stop { throw Stop(line: e.line, message: e.message) }
                                skipped += 1
                                if errors.count < 1_000 { errors.append(e) }
                            }
                        }
                    }
                    progress(ImportProgress(rowsRead: rowsRead, inserted: inserted, skipped: skipped, fraction: source.fractionRead))
                }
                _ = try await client.query("COMMIT")
                inTransaction = false
            } onCancel: {
                client.cancel()
            }
            report.committed = true
            report.inserted = inserted
            report.skipped = skipped
            report.errors = errors
        } catch {
            if inTransaction { _ = try? await client.query("ROLLBACK") }
            report.errors = errors
            report.skipped = skipped
            if let stop = error as? Stop {
                report.errors.append(ImportRowError(line: stop.line, message: stop.message))
                report.failure = "Line \(stop.line): \(stop.message)"
            } else if isCancel(error) || Task.isCancelled {
                report.cancelled = true
            } else {
                report.failure = describe(error)
            }
        }
        report.duration = Date().timeIntervalSince(start)
        progress(ImportProgress(rowsRead: rowsRead, inserted: report.committed ? inserted : 0, skipped: skipped, fraction: 1))
        return report
    }
}
