import Foundation
import MTPCore
import MTPUIKit

struct CompletionItem: Hashable {
    enum Kind: String {
        case keyword, table, view, column, function, schema, snippet

        var symbol: String {
            switch self {
            case .keyword: return "K"
            case .table: return "T"
            case .view: return "V"
            case .column: return "C"
            case .function: return "F"
            case .schema: return "S"
            case .snippet: return "★"
            }
        }
    }

    var text: String
    var kind: Kind
    var detail: String
    /// Text inserted instead of `text` (snippets expand to their SQL).
    var insertion: String?
}

/// Context-aware SQL suggestions: tables after FROM/JOIN, columns after `alias.`,
/// columns of the tables already referenced in the statement, then keywords/functions.
struct CompletionEngine {
    var objects: [DBObject]
    var columnsByTable: [String: [ColumnDef]]
    var schemas: [String]
    var favorites: [SavedQuery]
    var uppercaseKeywords: Bool

    /// - Parameters:
    ///   - statement: the statement around the caret (for alias resolution).
    ///   - prefix: identifier fragment being typed.
    ///   - qualifier: identifier before a dot, if any ("o" in "o.cu").
    ///   - previousWord: keyword before the fragment (FROM, JOIN, …).
    func suggestions(statement: String, prefix: String, qualifier: String?, previousWord: String?) -> [CompletionItem] {
        let p = prefix.lowercased()
        func matches(_ s: String) -> Bool { p.isEmpty || s.lowercased().hasPrefix(p) || (p.count >= 2 && s.lowercased().contains(p)) }
        func rank(_ a: CompletionItem, _ b: CompletionItem) -> Bool {
            let ap = a.text.lowercased().hasPrefix(p), bp = b.text.lowercased().hasPrefix(p)
            if ap != bp { return ap }
            return a.text.count < b.text.count || (a.text.count == b.text.count && a.text < b.text)
        }

        if let qualifier {
            let q = qualifier.replacingOccurrences(of: "\"", with: "")
            if schemas.contains(q) {
                let rel = objects.filter { $0.schema == q && $0.kind.hasData && matches($0.name) }
                return rel.map { CompletionItem(text: $0.name, kind: $0.kind == .table ? .table : .view, detail: $0.kind.sectionTitle) }.sorted(by: rank)
            }
            let aliases = Self.aliases(in: statement)
            let table = aliases[q.lowercased()] ?? q
            let cols = columnsByTable[table] ?? columnsByTable.first { $0.key.lowercased() == table.lowercased() }?.value ?? []
            return cols.filter { matches($0.name) }.map { CompletionItem(text: $0.name, kind: .column, detail: $0.dataType) }.sorted(by: rank)
        }

        let tableContext: Set<String> = ["FROM", "JOIN", "INTO", "UPDATE", "TABLE", "TRUNCATE", "DESCRIBE", "ANALYZE", "VACUUM"]
        var items: [CompletionItem] = []
        let relations = objects.filter { $0.kind.hasData && matches($0.name) }
            .map { CompletionItem(text: $0.name, kind: $0.kind == .table ? .table : .view, detail: $0.estimatedRows.map { "\(Fmt.compact($0)) rows" } ?? $0.kind.sectionTitle) }
        if let w = previousWord?.uppercased(), tableContext.contains(w) {
            items += relations.sorted(by: rank)
            items += schemas.filter(matches).map { CompletionItem(text: $0, kind: .schema, detail: "schema") }
            return items
        }

        // Columns of the tables the statement references first.
        var seen = Set<String>()
        let referenced = Set(Self.aliases(in: statement).values)
        for t in referenced.sorted() {
            for c in columnsByTable[t] ?? [] where matches(c.name) && !seen.contains(c.name) {
                seen.insert(c.name)
                items.append(CompletionItem(text: c.name, kind: .column, detail: "\(t) · \(c.dataType)"))
            }
        }
        items.sort(by: rank)
        guard !p.isEmpty else { return items }
        items += favorites.filter { !$0.keyword.isEmpty && $0.keyword.lowercased().hasPrefix(p) }
            .map { CompletionItem(text: $0.keyword, kind: .snippet, detail: $0.name, insertion: $0.sql) }
        items += relations.sorted(by: rank)
        let kw = SQLKeywords.all.filter { $0.lowercased().hasPrefix(p) }.sorted { $0.count < $1.count || ($0.count == $1.count && $0 < $1) }
        items += kw.prefix(30).map { CompletionItem(text: uppercaseKeywords ? $0 : $0.lowercased(), kind: .keyword, detail: "keyword") }
        items += SQLKeywords.functions.filter { $0.hasPrefix(p) }.map { CompletionItem(text: $0, kind: .function, detail: "function", insertion: $0 + "(") }
        var unique = Set<String>()
        return items.filter { unique.insert("\($0.kind.rawValue):\($0.text)").inserted }
    }

    /// alias (lower-cased) → table name, from FROM / JOIN / UPDATE / INTO clauses. Table names map to themselves.
    static func aliases(in statement: String) -> [String: String] {
        let tokens = SQLTokenizer.tokenize(statement).filter { !$0.kind.isTrivia }
        var out: [String: String] = [:]
        let starters: Set<String> = ["FROM", "JOIN", "UPDATE", "INTO"]
        let stop: Set<String> = ["WHERE", "ON", "JOIN", "LEFT", "RIGHT", "INNER", "FULL", "CROSS", "GROUP", "ORDER", "LIMIT", "SET", "USING",
                                 "VALUES", "RETURNING", "HAVING", "UNION", "NATURAL", "WINDOW", "OFFSET", "LATERAL"]
        var i = 0
        func name(_ t: SQLToken) -> String { t.kind == .quotedIdentifier ? String(t.text.dropFirst().dropLast()) : t.text }
        while i < tokens.count {
            if starters.contains(tokens[i].upper) {
                var j = i + 1
                while j < tokens.count {
                    let t = tokens[j]
                    guard t.kind == .identifier || t.kind == .quotedIdentifier || (t.kind == .keyword && !stop.contains(t.upper) && t.upper != "AS" && t.upper != "ONLY") else { break }
                    var table = name(t)
                    if j + 2 < tokens.count, tokens[j + 1].kind == .dot {
                        table = name(tokens[j + 2])
                        j += 2
                    }
                    out[table.lowercased()] = table
                    j += 1
                    if j < tokens.count, tokens[j].upper == "AS" { j += 1 }
                    if j < tokens.count, tokens[j].kind == .identifier || tokens[j].kind == .quotedIdentifier, !stop.contains(tokens[j].upper) {
                        out[name(tokens[j]).lowercased()] = table
                        j += 1
                    }
                    if j < tokens.count, tokens[j].kind == .comma { j += 1; continue }
                    break
                }
                i = j
            } else {
                i += 1
            }
        }
        return out
    }
}
