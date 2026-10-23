import Foundation

/// Broad value families used for alignment, editing widgets and code generation.
public enum ValueKind: String, Codable, Sendable {
    case text, integer, decimal, boolean, date, time, timestamp, json, uuid, binary, array, enumeration, interval, network, geometric, other
}

public struct ResultColumn: Hashable, Sendable, Codable {
    public var name: String
    /// Database type name, e.g. "int8", "jsonb", "timestamptz", "TEXT".
    public var typeName: String
    public var typeOID: UInt32
    /// PostgreSQL table OID the column comes from (0 when computed).
    public var tableOID: UInt32
    /// 1-based attribute number in `tableOID` (0 when computed).
    public var tableColumn: Int
    public var kind: ValueKind

    public init(name: String, typeName: String, typeOID: UInt32 = 0, tableOID: UInt32 = 0, tableColumn: Int = 0, kind: ValueKind? = nil) {
        self.name = name
        self.typeName = typeName
        self.typeOID = typeOID
        self.tableOID = tableOID
        self.tableColumn = tableColumn
        self.kind = kind ?? ValueKind.infer(typeName: typeName)
    }

    public var isNumeric: Bool { kind == .integer || kind == .decimal }
}

public extension ValueKind {
    static func infer(typeName raw: String) -> ValueKind {
        let t = raw.lowercased()
        if t.hasPrefix("_") || t.hasSuffix("[]") { return .array }
        switch t {
        case "int2", "int4", "int8", "smallint", "integer", "bigint", "int", "serial", "bigserial", "oid", "xid", "smallserial", "tinyint", "mediumint":
            return .integer
        case "numeric", "decimal", "float4", "float8", "real", "double precision", "money", "double", "float":
            return .decimal
        case "bool", "boolean":
            return .boolean
        case "date":
            return .date
        case "time", "timetz", "time without time zone", "time with time zone":
            return .time
        case "timestamp", "timestamptz", "timestamp without time zone", "timestamp with time zone", "datetime":
            return .timestamp
        case "json", "jsonb":
            return .json
        case "uuid":
            return .uuid
        case "bytea", "blob":
            return .binary
        case "interval":
            return .interval
        case "inet", "cidr", "macaddr", "macaddr8":
            return .network
        case "point", "line", "lseg", "box", "path", "polygon", "circle":
            return .geometric
        case "text", "varchar", "char", "bpchar", "name", "character varying", "character", "citext", "clob":
            return .text
        default:
            if t.contains("int") { return .integer }
            if t.contains("char") || t.contains("text") { return .text }
            if t.contains("real") || t.contains("floa") || t.contains("doub") || t.contains("dec") || t.contains("num") { return .decimal }
            return .other
        }
    }
}

public struct QueryResult: Sendable {
    public var columns: [ResultColumn]
    /// Text representation of every value; nil is SQL NULL.
    public var rows: [[String?]]
    /// Server command tag, e.g. "SELECT 300", "UPDATE 2".
    public var commandTag: String
    public var affectedRows: Int?
    public var duration: TimeInterval
    public var notices: [String]
    /// True when the row cap stopped the fetch early.
    public var isTruncated: Bool
    public var statement: String

    public init(columns: [ResultColumn] = [], rows: [[String?]] = [], commandTag: String = "", affectedRows: Int? = nil,
                duration: TimeInterval = 0, notices: [String] = [], isTruncated: Bool = false, statement: String = "") {
        self.columns = columns
        self.rows = rows
        self.commandTag = commandTag
        self.affectedRows = affectedRows
        self.duration = duration
        self.notices = notices
        self.isTruncated = isTruncated
        self.statement = statement
    }

    public var hasRows: Bool { !columns.isEmpty }

    public func columnIndex(_ name: String) -> Int? { columns.firstIndex { $0.name == name } }

    /// Values of one column by name (convenience for metadata queries).
    public func value(_ row: Int, _ column: String) -> String? {
        guard let i = columnIndex(column), row < rows.count else { return nil }
        return rows[row][i]
    }

    /// Rows as dictionaries; handy for introspection code.
    public var records: [[String: String?]] {
        rows.map { row in
            var d: [String: String?] = [:]
            for (i, c) in columns.enumerated() { d[c.name] = row[i] }
            return d
        }
    }

    public var summary: String {
        if hasRows {
            let n = rows.count
            return "\(n) row\(n == 1 ? "" : "s")\(isTruncated ? " (truncated)" : "") in \(Self.format(duration))"
        }
        if let a = affectedRows { return "\(commandTag.isEmpty ? "OK" : commandTag) — \(a) row\(a == 1 ? "" : "s") affected in \(Self.format(duration))" }
        return "\(commandTag.isEmpty ? "OK" : commandTag) in \(Self.format(duration))"
    }

    public static func format(_ d: TimeInterval) -> String {
        if d < 1 { return String(format: "%.0f ms", d * 1000) }
        if d < 60 { return String(format: "%.2f s", d) }
        return String(format: "%dm %02ds", Int(d) / 60, Int(d) % 60)
    }
}

public struct DatabaseError: Error, LocalizedError, Sendable {
    public var message: String
    public var detail: String?
    public var hint: String?
    public var sqlState: String?
    /// 1-based character position in the statement, when the server reports one.
    public var position: Int?

    public init(_ message: String, detail: String? = nil, hint: String? = nil, sqlState: String? = nil, position: Int? = nil) {
        self.message = message
        self.detail = detail
        self.hint = hint
        self.sqlState = sqlState
        self.position = position
    }

    public var errorDescription: String? { fullMessage }

    public var fullMessage: String {
        var parts = [message]
        if let detail, !detail.isEmpty { parts.append("DETAIL: \(detail)") }
        if let hint, !hint.isEmpty { parts.append("HINT: \(hint)") }
        return parts.joined(separator: "\n")
    }

    public var isCancellation: Bool { sqlState == "57014" }
}
