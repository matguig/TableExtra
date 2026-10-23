import Foundation
import MTPCore

/// Text helpers to compare catalog output across schemas and to rewrite it for another schema.
/// PostgreSQL omits the schema of objects visible on the search_path, so the same object can be printed
/// as `orders`, `public.orders` or `mtp_diff.orders` depending on where it lives.
enum SQLNormalizer {
    /// Removes `schema.` / `"schema".` qualifiers for the given schemas and collapses whitespace.
    static func normalize(_ sql: String, stripping schemas: Set<String>) -> String {
        var s = sql
        for schema in schemas where !schema.isEmpty {
            s = replaceQualifier(in: s, schema: schema, with: "")
        }
        return collapseWhitespace(s)
    }

    static func collapseWhitespace(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Replaces the `schema.` qualifier (quoted or not) by `replacement` (which should end with "." or be empty).
    static func replaceQualifier(in sql: String, schema: String, with replacement: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: schema)
        let quoted = NSRegularExpression.escapedPattern(for: "\"" + schema.replacingOccurrences(of: "\"", with: "\"\"") + "\"")
        let pattern = "(?<![A-Za-z0-9_$\"])(?:\(quoted)|\(escaped))\\."
        guard let re = try? NSRegularExpression(pattern: pattern) else { return sql }
        let range = NSRange(sql.startIndex..., in: sql)
        return re.stringByReplacingMatches(in: sql, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }

    /// Text after `USING` in a pg_get_indexdef string ("btree (customer_id) WHERE …"), prefixed with UNIQUE when relevant.
    /// Ignores the index name and the table qualification so that indexes compare by what they do.
    static func indexKey(_ index: IndexDef, stripping schemas: Set<String>) -> String {
        let def = index.definition
        let body: String
        if let r = def.range(of: " USING ") {
            body = String(def[r.upperBound...])
        } else {
            body = "\(index.method) (\(index.columns.joined(separator: ", ")))"
                + (index.predicate.map { " WHERE \($0)" } ?? "")
        }
        return (index.isUnique ? "UNIQUE " : "") + normalize(body, stripping: schemas)
    }

    /// The part of an index definition after the table name (`USING btree (…) …`).
    static func indexBody(_ index: IndexDef) -> String {
        if let r = index.definition.range(of: " USING ") {
            return "USING " + index.definition[r.upperBound...]
        }
        return "USING \(index.method) (\(index.columns.joined(separator: ", ")))" + (index.predicate.map { " WHERE \($0)" } ?? "")
    }
}

/// Rewrites source-schema SQL fragments (types, defaults, constraint and view bodies) so they apply to the target schema.
struct SchemaRetargeter {
    var sourceSchema: String
    var targetSchema: String
    var dialect: SQLDialect
    /// Enum type names defined in the source schema.
    var enumNames: Set<String>

    var isIdentity: Bool { sourceSchema == targetSchema || dialect.kind != .postgres }

    var targetPrefix: String { dialect.quoteIdentIfNeeded(targetSchema) + "." }

    func qualified(_ name: String) -> String {
        if dialect.kind == .sqlite && (targetSchema == "main" || targetSchema.isEmpty) { return dialect.quoteIdentIfNeeded(name) }
        return targetPrefix + dialect.quoteIdentIfNeeded(name)
    }

    /// Generic rewrite: `source.` qualifiers become `target.`.
    func expression(_ sql: String) -> String {
        guard !isIdentity else { return sql }
        return SQLNormalizer.replaceQualifier(in: sql, schema: sourceSchema, with: targetPrefix)
    }

    /// Column type: enums of the source schema are qualified with the target schema.
    func type(_ dataType: String) -> String {
        guard !isIdentity else { return dataType }
        var t = SQLNormalizer.replaceQualifier(in: dataType, schema: sourceSchema, with: "")
        var suffix = ""
        while t.hasSuffix("[]") {
            t.removeLast(2)
            suffix += "[]"
        }
        let bare = t.hasPrefix("\"") && t.hasSuffix("\"") && t.count > 1 ? String(t.dropFirst().dropLast()).replacingOccurrences(of: "\"\"", with: "\"") : t
        if enumNames.contains(bare) { return qualified(bare) + suffix }
        return expression(dataType)
    }

    /// Default expression: also qualifies unqualified sequences in nextval() and enum casts.
    func defaultExpression(_ sql: String) -> String {
        guard !isIdentity else { return sql }
        var s = expression(sql)
        // nextval('seq'::regclass) → nextval('target.seq'::regclass)
        if let re = try? NSRegularExpression(pattern: "nextval\\('([^'.]+)'::regclass\\)") {
            let ns = s as NSString
            var out = ""
            var last = 0
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let seq = ns.substring(with: m.range(at: 1))
                out += "nextval('\(qualifiedSequenceLiteral(seq))'::regclass)"
                last = m.range.location + m.range.length
            }
            out += ns.substring(from: last)
            s = out
        }
        for e in enumNames {
            let pattern = "::(?:\(NSRegularExpression.escapedPattern(for: e))|\(NSRegularExpression.escapedPattern(for: "\"" + e + "\"")))(?![A-Za-z0-9_$.\"])"
            if let re = try? NSRegularExpression(pattern: pattern) {
                s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s),
                                                withTemplate: NSRegularExpression.escapedTemplate(for: "::" + qualified(e)))
            }
        }
        return s
    }

    /// Sequence name inside a regclass literal; quotes are kept as typed in the original.
    private func qualifiedSequenceLiteral(_ seq: String) -> String {
        let schema = dialect.quoteIdentIfNeeded(targetSchema).replacingOccurrences(of: "'", with: "''")
        return "\(schema).\(seq)"
    }
}

/// Sequence referenced by a `nextval('…'::regclass)` default, without schema.
func sequenceName(inDefault value: String?) -> String? {
    guard let value, let r = value.range(of: "nextval('") else { return nil }
    let rest = value[r.upperBound...]
    guard let end = rest.range(of: "'") else { return nil }
    var name = String(rest[..<end.lowerBound])
    if let dot = name.lastIndex(of: ".") { name = String(name[name.index(after: dot)...]) }
    if name.hasPrefix("\"") && name.hasSuffix("\"") && name.count > 1 { name = String(name.dropFirst().dropLast()) }
    return name
}
