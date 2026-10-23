import Foundation

public enum FilterOperator: String, Codable, CaseIterable, Sendable, Identifiable {
    case equals = "="
    case notEquals = "<>"
    case less = "<"
    case greater = ">"
    case lessOrEqual = "<="
    case greaterOrEqual = ">="
    case isIn = "IN"
    case notIn = "NOT IN"
    case isNull = "IS NULL"
    case isNotNull = "IS NOT NULL"
    case between = "BETWEEN"
    case notBetween = "NOT BETWEEN"
    case like = "LIKE"
    case notLike = "NOT LIKE"
    case contains = "Contains"
    case notContains = "Not contains"
    case containsCaseInsensitive = "Contains (case insensitive)"
    case startsWith = "Has prefix"
    case endsWith = "Has suffix"
    case isEmpty = "Is empty"
    case isNotEmpty = "Is not empty"
    case regex = "Matches regex"
    case raw = "Raw SQL"

    public var id: String { rawValue }

    public var needsValue: Bool {
        switch self {
        case .isNull, .isNotNull, .isEmpty, .isNotEmpty: return false
        default: return true
        }
    }

    public var needsSecondValue: Bool { self == .between || self == .notBetween }
}

public struct FilterRule: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    /// nil means "any column" (text search across every column).
    public var column: String?
    public var op: FilterOperator
    public var value: String
    public var value2: String
    public var isEnabled: Bool

    public init(column: String?, op: FilterOperator = .equals, value: String = "", value2: String = "", isEnabled: Bool = true) {
        self.column = column
        self.op = op
        self.value = value
        self.value2 = value2
        self.isEnabled = isEnabled
    }
}

public struct SortKey: Codable, Hashable, Sendable {
    public var column: String
    public var ascending: Bool

    public init(column: String, ascending: Bool = true) {
        self.column = column
        self.ascending = ascending
    }
}

/// Builds the SELECT / COUNT statements behind a table data tab.
public struct TableQuery: Sendable {
    public var schema: String
    public var table: String
    public var columns: [ColumnDef]
    public var filters: [FilterRule]
    public var matchAll: Bool
    public var sort: [SortKey]
    public var limit: Int
    public var offset: Int
    /// Select ctid / rowid as an extra trailing column to edit tables without primary key.
    public var includeRowID: Bool
    public var dialect: SQLDialect

    public init(schema: String, table: String, columns: [ColumnDef], filters: [FilterRule] = [], matchAll: Bool = true,
                sort: [SortKey] = [], limit: Int = 300, offset: Int = 0, includeRowID: Bool = false, dialect: SQLDialect) {
        self.schema = schema
        self.table = table
        self.columns = columns
        self.filters = filters
        self.matchAll = matchAll
        self.sort = sort
        self.limit = limit
        self.offset = offset
        self.includeRowID = includeRowID
        self.dialect = dialect
    }

    public static let rowIDAlias = "__mtp_rowid"

    public var qualifiedTable: String { dialect.qualified(schema: schema, name: table) }

    public func whereClause(startingAt firstParam: Int = 1) -> (sql: String, params: [String?]) {
        var params: [String?] = []
        func p(_ v: String?) -> String {
            params.append(v)
            return dialect.placeholder(firstParam + params.count - 1)
        }
        let parts: [String] = filters.filter(\.isEnabled).compactMap { rule in
            if rule.op == .raw { return rule.value.trimmingCharacters(in: .whitespaces).isEmpty ? nil : "(\(rule.value))" }
            if rule.op.needsValue && rule.value.isEmpty && rule.op != .equals && rule.op != .notEquals { return nil }
            if let column = rule.column {
                return condition(column: dialect.quoteIdent(column), rule: rule, isText: isTextColumn(column), p)
            }
            // Any column: OR over text casts of every column.
            guard !columns.isEmpty else { return nil }
            let ors = columns.map { condition(column: dialect.quoteIdent($0.name), rule: rule, isText: false, p) }
            return "(" + ors.joined(separator: " OR ") + ")"
        }
        guard !parts.isEmpty else { return ("", []) }
        return (" WHERE " + parts.joined(separator: matchAll ? " AND " : " OR "), params)
    }

    private func isTextColumn(_ name: String) -> Bool {
        guard let c = columns.first(where: { $0.name == name }) else { return false }
        return c.kind == .text
    }

    private func condition(column: String, rule: FilterRule, isText: Bool, _ p: (String?) -> String) -> String {
        let textExpr = isText ? column : dialect.castToText(column)
        let ilike = dialect.caseInsensitiveLike
        // PostgreSQL uses backslash as the LIKE escape by default; SQLite needs it spelled out.
        let escape = dialect.kind == .sqlite ? " ESCAPE '\\'" : ""
        switch rule.op {
        case .equals, .notEquals, .less, .greater, .lessOrEqual, .greaterOrEqual:
            if rule.column == nil { return "\(textExpr) \(rule.op.rawValue) \(p(rule.value))" }
            return "\(column) \(rule.op.rawValue) \(p(rule.value))"
        case .isIn, .notIn:
            let items = rule.value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard !items.isEmpty else { return "TRUE" }
            let placeholders = items.map { p($0) }.joined(separator: ", ")
            return "\(rule.column == nil ? textExpr : column) \(rule.op.rawValue) (\(placeholders))"
        case .isNull: return "\(column) IS NULL"
        case .isNotNull: return "\(column) IS NOT NULL"
        case .isEmpty: return "(\(column) IS NULL OR \(textExpr) = '')"
        case .isNotEmpty: return "(\(column) IS NOT NULL AND \(textExpr) <> '')"
        case .between, .notBetween:
            return "\(column) \(rule.op.rawValue) \(p(rule.value)) AND \(p(rule.value2))"
        case .like: return "\(textExpr) LIKE \(p(rule.value))"
        case .notLike: return "\(textExpr) NOT LIKE \(p(rule.value))"
        case .contains: return "\(textExpr) LIKE \(p("%" + Self.escapeLike(rule.value) + "%"))\(escape)"
        case .notContains: return "\(textExpr) NOT LIKE \(p("%" + Self.escapeLike(rule.value) + "%"))\(escape)"
        case .containsCaseInsensitive: return "\(textExpr) \(ilike) \(p("%" + Self.escapeLike(rule.value) + "%"))\(escape)"
        case .startsWith: return "\(textExpr) LIKE \(p(Self.escapeLike(rule.value) + "%"))\(escape)"
        case .endsWith: return "\(textExpr) LIKE \(p("%" + Self.escapeLike(rule.value)))\(escape)"
        case .regex:
            return dialect.kind == .postgres ? "\(textExpr) ~ \(p(rule.value))" : "\(textExpr) LIKE \(p("%" + rule.value + "%"))"
        case .raw: return rule.value
        }
    }

    static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    }

    public func selectSQL() -> SQLStatementWithParams {
        let w = whereClause()
        var cols = columns.isEmpty ? "*" : columns.map { dialect.quoteIdent($0.name) }.joined(separator: ", ")
        if includeRowID { cols += ", \(dialect.rowIDColumn) AS \(Self.rowIDAlias)" }
        var sql = "SELECT \(cols) FROM \(qualifiedTable)\(w.sql)"
        if !sort.isEmpty {
            sql += " ORDER BY " + sort.map { "\(dialect.quoteIdent($0.column)) \($0.ascending ? "ASC" : "DESC")" }.joined(separator: ", ")
        }
        sql += " LIMIT \(limit) OFFSET \(offset)"
        return SQLStatementWithParams(sql, w.params)
    }

    public func countSQL() -> SQLStatementWithParams {
        let w = whereClause()
        return SQLStatementWithParams("SELECT count(*) FROM \(qualifiedTable)\(w.sql)", w.params)
    }

    /// Human-readable version of the current SELECT, for "Copy SQL" and previews.
    public func displaySQL() -> String {
        let s = selectSQL()
        return SQLInterpolator.inline(s.sql, params: s.params, dialect: dialect)
    }
}

public enum SQLInterpolator {
    /// Replaces $n / ?n placeholders with quoted literals (display only, never executed).
    public static func inline(_ sql: String, params: [String?], dialect: SQLDialect) -> String {
        guard !params.isEmpty else { return sql }
        let tokens = SQLTokenizer.tokenize(sql)
        var out = ""
        for t in tokens {
            if t.kind == .parameter, let n = Int(t.text.dropFirst()), n >= 1, n <= params.count {
                out += dialect.quoteLiteral(params[n - 1])
            } else {
                out += t.text
            }
        }
        return out
    }
}
