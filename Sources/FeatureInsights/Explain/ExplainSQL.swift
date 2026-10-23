import Foundation
import MTPCore

public enum ExplainFormat: String, Sendable {
    case json = "JSON"
    case text = "TEXT"
}

/// Builds EXPLAIN statements from whatever the user selected (with or without an EXPLAIN prefix).
public enum ExplainSQL {
    /// First statement of `sql` without trailing semicolons or an existing `EXPLAIN [ANALYZE] [VERBOSE] | EXPLAIN (…)` prefix.
    /// SQLite's `EXPLAIN QUERY PLAN` prefix is removed too.
    public static func innerStatement(_ sql: String) -> String {
        let statements = StatementSplitter.split(sql).map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        var statement = statements.first { !$0.isEmpty } ?? sql.trimmingCharacters(in: .whitespacesAndNewlines)
        while statement.hasSuffix(";") {
            statement.removeLast()
            statement = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let tokens = SQLTokenizer.tokenize(statement).filter { !$0.kind.isTrivia }
        guard let first = tokens.first, first.is("EXPLAIN") else { return statement }
        var i = 1
        if i < tokens.count, tokens[i].kind == .openParen {
            var depth = 0
            while i < tokens.count {
                if tokens[i].kind == .openParen { depth += 1 }
                if tokens[i].kind == .closeParen {
                    depth -= 1
                    if depth == 0 { i += 1; break }
                }
                i += 1
            }
        } else {
            while i < tokens.count, ["ANALYZE", "ANALYSE", "VERBOSE"].contains(tokens[i].upper) { i += 1 }
            if i + 1 < tokens.count, tokens[i].is("QUERY"), tokens[i + 1].is("PLAN") { i += 2 }
        }
        guard i < tokens.count else { return "" }
        let ns = statement as NSString
        return ns.substring(from: tokens[i].location).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `EXPLAIN (FORMAT …, VERBOSE, BUFFERS[, ANALYZE][, SETTINGS]) <statement>`.
    /// BUFFERS needs ANALYZE before PostgreSQL 13, SETTINGS exists since 12.
    public static func postgres(_ statement: String, format: ExplainFormat, analyze: Bool, serverVersion: Int) -> String {
        var options = ["FORMAT \(format.rawValue)", "VERBOSE"]
        if analyze || serverVersion == 0 || serverVersion >= 130000 { options.append("BUFFERS") }
        if analyze { options.append("ANALYZE") }
        if serverVersion >= 120000 { options.append("SETTINGS") }
        return "EXPLAIN (\(options.joined(separator: ", "))) \(statement)"
    }

    public static func sqlite(_ statement: String) -> String {
        "EXPLAIN QUERY PLAN \(statement)"
    }
}

/// One row of SQLite's `EXPLAIN QUERY PLAN`, arranged as a tree.
public struct SQLiteQueryPlanNode: Identifiable, Hashable, Sendable {
    public var id: Int
    public var parent: Int
    public var detail: String
    public var depth: Int
    public var children: [SQLiteQueryPlanNode]

    /// Full table scan without an index ("SCAN t" but not "SCAN t USING INDEX …").
    public var isFullScan: Bool {
        let d = detail.uppercased()
        return d.hasPrefix("SCAN ") && !d.contains(" USING ") && !d.contains("CONSTANT ROW")
    }

    public var usesTempBTree: Bool { detail.uppercased().contains("TEMP B-TREE") }

    public var flattened: [SQLiteQueryPlanNode] {
        [self] + children.flatMap(\.flattened)
    }
}

public enum SQLiteQueryPlan {
    /// Builds the tree from rows (id, parent, notused, detail). Unknown parents attach to the root level.
    public static func build(from result: QueryResult) -> [SQLiteQueryPlanNode] {
        let idIndex = result.columnIndex("id") ?? 0
        let parentIndex = result.columnIndex("parent") ?? 1
        let detailIndex = result.columnIndex("detail") ?? (result.columns.count - 1)
        let rows: [(id: Int, parent: Int, detail: String)] = result.rows.compactMap { row in
            guard idIndex < row.count, parentIndex < row.count, detailIndex >= 0, detailIndex < row.count else { return nil }
            return (Int(row[idIndex] ?? "") ?? 0, Int(row[parentIndex] ?? "") ?? 0, row[detailIndex] ?? "")
        }
        return build(rows)
    }

    public static func build(_ rows: [(id: Int, parent: Int, detail: String)]) -> [SQLiteQueryPlanNode] {
        let ids = Set(rows.map(\.id))
        var childrenOf: [Int: [(id: Int, parent: Int, detail: String)]] = [:]
        var roots: [(id: Int, parent: Int, detail: String)] = []
        for r in rows {
            if r.parent != 0, ids.contains(r.parent), r.parent != r.id {
                childrenOf[r.parent, default: []].append(r)
            } else {
                roots.append(r)
            }
        }
        var visited: Set<Int> = []
        func make(_ r: (id: Int, parent: Int, detail: String), depth: Int) -> SQLiteQueryPlanNode {
            visited.insert(r.id)
            let kids = (childrenOf[r.id] ?? []).filter { !visited.contains($0.id) }.map { make($0, depth: depth + 1) }
            return SQLiteQueryPlanNode(id: r.id, parent: r.parent, detail: r.detail, depth: depth, children: kids)
        }
        return roots.map { make($0, depth: 0) }
    }
}
