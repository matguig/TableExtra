import Foundation

public struct SQLDialect: Sendable, Hashable {
    public let kind: DriverKind

    public init(kind: DriverKind) { self.kind = kind }

    public func quoteIdent(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Identifiers that need no quoting stay readable in generated SQL.
    public func quoteIdentIfNeeded(_ name: String) -> String {
        let simple = name.range(of: "^[a-z_][a-z0-9_$]*$", options: .regularExpression) != nil
        if simple && !SQLKeywords.reserved.contains(name.uppercased()) { return name }
        return quoteIdent(name)
    }

    public func quoteLiteral(_ value: String?) -> String {
        guard let value else { return "NULL" }
        return "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    public func qualified(schema: String?, name: String) -> String {
        guard let schema, !schema.isEmpty else { return quoteIdent(name) }
        if kind == .sqlite && schema == "main" { return quoteIdent(name) }
        return quoteIdent(schema) + "." + quoteIdent(name)
    }

    /// 1-based positional parameter.
    public func placeholder(_ index: Int) -> String {
        switch kind {
        case .postgres: return "$\(index)"
        case .sqlite: return "?\(index)"
        }
    }

    public func castToText(_ expression: String) -> String {
        switch kind {
        case .postgres: return "\(expression)::text"
        case .sqlite: return "CAST(\(expression) AS TEXT)"
        }
    }

    public var caseInsensitiveLike: String { kind == .postgres ? "ILIKE" : "LIKE" }

    /// Hidden physical row id used to edit tables without a primary key.
    public var rowIDColumn: String {
        switch kind {
        case .postgres: return "ctid"
        case .sqlite: return "rowid"
        }
    }

    public func rowIDComparison(_ placeholder: String) -> String {
        switch kind {
        case .postgres: return "ctid = \(placeholder)::tid"
        case .sqlite: return "rowid = \(placeholder)"
        }
    }

    /// Literal for display in SQL previews; numbers and booleans stay bare.
    public func literal(_ value: String?, kind valueKind: ValueKind) -> String {
        guard let value else { return "NULL" }
        switch valueKind {
        case .integer, .decimal:
            if Double(value) != nil { return value }
        case .boolean:
            if ["true", "false", "t", "f"].contains(value.lowercased()) { return value.lowercased().hasPrefix("t") ? "TRUE" : "FALSE" }
        default:
            break
        }
        return quoteLiteral(value)
    }
}
