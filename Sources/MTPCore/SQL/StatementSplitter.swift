import Foundation

public struct SQLStatementRange: Sendable, Equatable {
    /// UTF-16 range of the statement in the source text, without the trailing semicolon.
    public var range: NSRange
    public var text: String

    public init(range: NSRange, text: String) {
        self.range = range
        self.text = text
    }
}

public enum StatementSplitter {
    /// Splits a script on top-level semicolons. Strings, comments, dollar quotes and
    /// BEGIN…END bodies (SQLite triggers, SQL-standard function bodies) are respected.
    public static func split(_ sql: String) -> [SQLStatementRange] {
        let tokens = SQLTokenizer.tokenize(sql)
        let ns = sql as NSString
        var out: [SQLStatementRange] = []
        var stmtStart: Int?
        var lastSignificantEnd = 0
        var depth = 0
        var significant: [SQLToken] = []

        func flush(until end: Int) {
            guard let s = stmtStart else { return }
            let r = NSRange(location: s, length: max(0, end - s))
            let text = ns.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { out.append(SQLStatementRange(range: r, text: text)) }
            stmtStart = nil
            depth = 0
            significant.removeAll()
        }

        for t in tokens {
            if t.kind.isTrivia {
                // Comments directly above a statement belong to it.
                if t.kind.isComment, stmtStart == nil { stmtStart = t.location }
                continue
            }
            if t.kind == .semicolon && depth == 0 {
                flush(until: lastSignificantEnd)
                continue
            }
            if stmtStart == nil { stmtStart = t.location }
            if t.kind == .keyword || t.kind == .identifier {
                let w = t.upper
                let isCreateBody = significant.first?.is("CREATE") == true
                if w == "CASE" { depth += 1 }
                else if w == "BEGIN" && isCreateBody { depth += 1 }
                else if w == "END" && depth > 0 {
                    // "END IF" / "END LOOP" inside plpgsql never reach here (dollar-quoted).
                    depth -= 1
                }
            }
            significant.append(t)
            lastSignificantEnd = t.end
        }
        flush(until: lastSignificantEnd)
        return out
    }

    /// Statement under the caret; when the caret sits after a statement's semicolon on the
    /// same line, or in blank space, the closest preceding statement wins (TablePlus behaviour).
    public static func statement(at caret: Int, in sql: String) -> SQLStatementRange? {
        let all = split(sql)
        guard !all.isEmpty else { return nil }
        if let hit = all.first(where: { caret >= $0.range.location && caret <= NSMaxRange($0.range) }) { return hit }
        let before = all.last { NSMaxRange($0.range) <= caret }
        let after = all.first { $0.range.location >= caret }
        guard let before else { return after }
        guard let after else { return before }
        // Prefer the following statement only if there is no blank line between caret and it.
        let ns = sql as NSString
        let gapBefore = ns.substring(with: NSRange(location: NSMaxRange(before.range), length: caret - NSMaxRange(before.range)))
        if gapBefore.components(separatedBy: "\n").count <= 2 { return before }
        return after
    }
}
