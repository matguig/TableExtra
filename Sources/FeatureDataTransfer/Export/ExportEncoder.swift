import Foundation
import MTPCore

/// Incremental writer for one export: `header()`, then `encode(_:)` for each page of rows, then `footer()`.
/// `DataExporter.render` and the streaming table export share it, so both produce identical output.
public struct ExportEncoder {
    public let format: ExportFormat
    public let columns: [ResultColumn]
    public let options: ExportOptions
    public let dialect: SQLDialect
    /// Target of SQL INSERT statements, already quoted.
    public let target: String
    public private(set) var rowCount = 0

    private let delimiter: Character
    private let newline: String
    private let jsonKeys: [String]
    private let sqlColumnList: String

    public init(format: ExportFormat, columns: [ResultColumn], options: ExportOptions = ExportOptions(), tableName: String? = nil,
                schema: String? = nil, dialect: SQLDialect = SQLDialect(kind: .postgres)) {
        self.format = format
        self.columns = columns
        self.options = options
        self.dialect = dialect
        delimiter = format == .tsv ? "\t" : options.delimiterCharacter
        newline = (format == .csv || format == .tsv) ? options.lineEnding.string : "\n"

        var schemaName = schema
        var name = tableName ?? "result"
        if schemaName == nil, let dot = name.firstIndex(of: "."), dot != name.startIndex, name.index(after: dot) != name.endIndex {
            schemaName = String(name[..<dot])
            name = String(name[name.index(after: dot)...])
        }
        target = Self.qualifiedName(schema: schemaName, name: name, dialect: dialect)
        sqlColumnList = columns.map { dialect.quoteIdentIfNeeded($0.name) }.joined(separator: ", ")

        // Duplicate column names (joins) would produce ambiguous JSON objects.
        var seen: [String: Int] = [:]
        jsonKeys = columns.map { c in
            let n = (seen[c.name] ?? 0) + 1
            seen[c.name] = n
            return JSONText.quote(n == 1 ? c.name : "\(c.name)_\(n)")
        }
    }

    static func qualifiedName(schema: String?, name: String, dialect: SQLDialect) -> String {
        guard let schema, !schema.isEmpty, !(dialect.kind == .sqlite && schema == "main") else { return dialect.quoteIdentIfNeeded(name) }
        return dialect.quoteIdentIfNeeded(schema) + "." + dialect.quoteIdentIfNeeded(name)
    }

    // MARK: Stream parts

    public mutating func header() -> String {
        switch format {
        case .csv, .tsv:
            guard options.includeHeader else { return "" }
            return columns.map { delimitedField($0.name, isHeader: true) }.joined(separator: String(delimiter)) + newline
        case .json:
            return "["
        case .jsonLines, .sqlInsert:
            return ""
        case .markdown:
            let names = "| " + columns.map { markdownCell($0.name) }.joined(separator: " | ") + " |"
            let rule = "| " + columns.map { $0.isNumeric ? "---:" : "---" }.joined(separator: " | ") + " |"
            return columns.isEmpty ? "" : names + "\n" + rule + "\n"
        }
    }

    public mutating func encode(_ rows: [[String?]]) -> String {
        guard !rows.isEmpty else { return "" }
        var out = ""
        out.reserveCapacity(rows.count * max(columns.count, 1) * 12)
        switch format {
        case .csv, .tsv:
            let sep = String(delimiter)
            for row in rows {
                var first = true
                for i in columns.indices {
                    if !first { out += sep }
                    first = false
                    out += delimitedField(value(row, i), isHeader: false)
                }
                out += newline
            }
        case .json:
            for row in rows {
                if rowCount > 0 { out += "," }
                out += options.prettyJSON ? "\n  " : "\n"
                out += jsonObject(row, pretty: options.prettyJSON, level: 1)
                rowCount += 1
            }
            return out
        case .jsonLines:
            for row in rows {
                out += jsonObject(row, pretty: false, level: 0)
                out += "\n"
            }
        case .sqlInsert:
            let batch = options.effectiveBatchSize
            var start = 0
            while start < rows.count {
                let end = min(start + batch, rows.count)
                if batch == 1 {
                    out += "INSERT INTO \(target) (\(sqlColumnList)) VALUES \(sqlTuple(rows[start]));\n"
                } else {
                    out += "INSERT INTO \(target) (\(sqlColumnList)) VALUES\n"
                    for r in start..<end {
                        out += "  " + sqlTuple(rows[r]) + (r == end - 1 ? ";\n" : ",\n")
                    }
                }
                start = end
            }
        case .markdown:
            for row in rows {
                out += "| " + columns.indices.map { i in
                    guard let v = value(row, i) else { return options.nullStyle == .keyword ? "NULL" : "" }
                    return markdownCell(v)
                }.joined(separator: " | ") + " |\n"
            }
        }
        rowCount += rows.count
        return out
    }

    public func footer() -> String {
        switch format {
        case .json: return rowCount == 0 ? "]\n" : "\n]\n"
        default: return ""
        }
    }

    private func value(_ row: [String?], _ i: Int) -> String? { i < row.count ? row[i] : nil }

    // MARK: CSV / TSV

    /// RFC 4180: quote when the value holds the delimiter, a quote or a line break; double the quotes.
    /// With NULL written as empty, empty strings are quoted ("") so the two stay distinguishable,
    /// and with NULL written as NULL, the literal text NULL is quoted.
    func delimitedField(_ v: String?, isHeader: Bool) -> String {
        guard let v else { return options.nullStyle == .keyword ? "NULL" : "" }
        if !isHeader {
            if v.isEmpty { return options.nullStyle == .empty ? "\"\"" : "" }
            if options.nullStyle == .keyword && v == "NULL" { return "\"NULL\"" }
        }
        let needsQuotes: Bool
        if let d = delimiter.asciiValue {
            needsQuotes = v.utf8.contains { $0 == d || $0 == 0x22 || $0 == 0x0A || $0 == 0x0D }
        } else {
            needsQuotes = v.contains(delimiter) || v.contains("\"") || v.contains("\n") || v.contains("\r")
        }
        guard needsQuotes else { return v }
        return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: JSON

    func jsonObject(_ row: [String?], pretty: Bool, level: Int) -> String {
        guard !columns.isEmpty else { return "{}" }
        var s = "{"
        for (i, c) in columns.enumerated() {
            if i > 0 { s += "," }
            if pretty { s += "\n" + JSONText.indent(level + 1) }
            s += jsonKeys[i]
            s += pretty ? ": " : ":"
            jsonValue(value(row, i), kind: c.kind, pretty: pretty, level: level + 1, into: &s)
        }
        if pretty { s += "\n" + JSONText.indent(level) }
        s += "}"
        return s
    }

    func jsonValue(_ v: String?, kind: ValueKind, pretty: Bool, level: Int, into s: inout String) {
        guard let v else { s += "null"; return }
        switch kind {
        case .integer, .decimal:
            if JSONText.isNumber(v) { s += v; return }
        case .boolean:
            switch v.lowercased() {
            case "t", "true", "1": s += "true"; return
            case "f", "false", "0": s += "false"; return
            default: break
            }
        case .json:
            if let parsed = JSONText.parse(v) {
                JSONText.write(parsed, pretty: pretty, level: level, into: &s)
                return
            }
        default:
            break
        }
        s += JSONText.quote(v)
    }

    // MARK: SQL

    func sqlTuple(_ row: [String?]) -> String {
        "(" + columns.indices.map { sqlLiteral(value(row, $0), kind: columns[$0].kind) }.joined(separator: ", ") + ")"
    }

    func sqlLiteral(_ v: String?, kind: ValueKind) -> String {
        guard let v else { return "NULL" }
        switch kind {
        case .integer, .decimal:
            if Self.isSQLNumber(v) { return v }
        case .boolean:
            switch v.lowercased() {
            case "t", "true", "1": return dialect.kind == .sqlite ? "1" : "TRUE"
            case "f", "false", "0": return dialect.kind == .sqlite ? "0" : "FALSE"
            default: break
            }
        case .binary:
            if dialect.kind == .sqlite, v.range(of: "^[xX]'[0-9a-fA-F]*'$", options: .regularExpression) != nil { return v }
        default:
            break
        }
        return dialect.quoteLiteral(v)
    }

    static func isSQLNumber(_ s: String) -> Bool {
        s.range(of: "^[+-]?([0-9]+(\\.[0-9]*)?|\\.[0-9]+)([eE][+-]?[0-9]+)?$", options: .regularExpression) != nil
    }

    // MARK: Markdown

    func markdownCell(_ v: String) -> String {
        var s = v.replacingOccurrences(of: "|", with: "\\|")
        if s.contains(where: \.isNewline) {
            s = s.replacingOccurrences(of: "\r\n", with: "<br>")
                .replacingOccurrences(of: "\n", with: "<br>")
                .replacingOccurrences(of: "\r", with: "<br>")
        }
        return s
    }
}
