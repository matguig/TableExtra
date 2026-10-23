import Foundation

/// Lightweight, token-based SQL beautifier. Never changes literals, identifiers or comments.
public enum SQLFormatter {
    public struct Options: Sendable {
        public var uppercaseKeywords = true
        public var indent = "  "

        public init(uppercaseKeywords: Bool = true, indent: String = "  ") {
            self.uppercaseKeywords = uppercaseKeywords
            self.indent = indent
        }
    }

    public static func format(_ sql: String, options: Options = Options()) -> String {
        StatementSplitter.split(sql).map { formatStatement($0.text, options: options) }.joined(separator: ";\n\n") + (sql.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(";") ? ";" : "")
    }

    static let newlineBefore: Set<String> = ["SELECT", "FROM", "WHERE", "GROUP", "HAVING", "ORDER", "LIMIT", "OFFSET", "UNION",
                                             "INTERSECT", "EXCEPT", "VALUES", "SET", "RETURNING", "WINDOW", "LEFT", "RIGHT",
                                             "INNER", "FULL", "CROSS", "JOIN", "ON", "INSERT", "UPDATE", "DELETE", "WITH", "FETCH"]
    static let joinPrefixes: Set<String> = ["LEFT", "RIGHT", "INNER", "FULL", "CROSS", "NATURAL", "OUTER"]

    static func formatStatement(_ sql: String, options: Options) -> String {
        let tokens = SQLTokenizer.tokenize(sql)
        var out = ""
        var depth = 0
        var parenStack: [Bool] = [] // true when the paren holds a subquery
        var clause = ""
        var lineStart = true
        var prev: SQLToken?
        var prevSignificant: SQLToken?

        func indentString(_ extra: Int = 0) -> String { String(repeating: options.indent, count: max(0, depth + extra)) }
        func newline(_ extra: Int = 0) {
            while out.last == " " { out.removeLast() }
            if !out.isEmpty { out += "\n" }
            out += indentString(extra)
            lineStart = true
        }
        func append(_ s: String, spaceBefore: Bool = true) {
            if !lineStart, spaceBefore, let last = out.last, last != " ", last != "(", last != "\n", last != "." { out += " " }
            out += s
            lineStart = false
        }

        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            defer {
                if !t.kind.isTrivia { prevSignificant = t }
                prev = t
                i += 1
            }
            switch t.kind {
            case .whitespace:
                continue
            case .lineComment:
                append(t.text)
                newline()
                continue
            case .blockComment:
                append(t.text)
                continue
            default:
                break
            }
            var text = t.text
            if t.kind == .keyword && options.uppercaseKeywords { text = text.uppercased() }
            let upper = t.upper
            let isWord = t.kind == .keyword

            if isWord && newlineBefore.contains(upper) && !(prevSignificant.map { joinPrefixes.contains($0.upper) } ?? false) {
                let insideSubqueryStart = prevSignificant?.kind == .openParen
                if upper == "ON" {
                    newline(1)
                } else if !(upper == "SET" && clause == "UPDATE" && false) && !insideSubqueryStart && !(upper == "UPDATE" && clause == "ON") && !(upper == "SET" && prevSignificant?.upper == "DO") {
                    if !out.isEmpty { newline() }
                }
                if !["ON", "JOIN"].contains(upper) { clause = upper }
                append(text)
                continue
            }
            if isWord && (upper == "AND" || upper == "OR") && (clause == "WHERE" || clause == "HAVING" || clause == "ON") && parenStack.allSatisfy({ $0 }) {
                newline(1)
                append(text)
                continue
            }
            switch t.kind {
            case .comma:
                out += ","
                if (clause == "SELECT" || clause == "SET" || clause == "GROUP" || clause == "ORDER" || clause == "RETURNING") && (parenStack.last ?? true) && depthOfClauseIsCurrent(parenStack) {
                    newline(1)
                } else {
                    lineStart = false
                }
            case .openParen:
                let nextWord = tokens[(i + 1)...].first { !$0.kind.isTrivia }
                let subquery = nextWord.map { $0.is("SELECT") || $0.is("WITH") } ?? false
                let isCall = prev.map { !$0.kind.isTrivia && ($0.kind == .identifier || $0.kind == .quotedIdentifier || $0.kind == .keyword) } ?? false
                append("(", spaceBefore: !isCall)
                parenStack.append(subquery)
                if subquery { depth += 1; newline() }
            case .closeParen:
                let wasSubquery = parenStack.popLast() ?? false
                if wasSubquery { depth = max(0, depth - 1); newline() }
                out += ")"
                lineStart = false
            case .dot:
                out += "."
                lineStart = false
            case .semicolon:
                out += ";"
            default:
                let noSpace = prev?.kind == .dot || (prev?.kind == .openParen)
                    || (t.kind == .operator && t.text == "::") || (prev?.kind == .operator && prev?.text == "::")
                append(text, spaceBefore: !noSpace)
                if clause == "SELECT", isWord, upper == "SELECT" || upper == "DISTINCT" {
                    // keep first column on the same line
                }
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func depthOfClauseIsCurrent(_ stack: [Bool]) -> Bool {
        // Commas inside function calls stay inline.
        stack.allSatisfy { $0 }
    }
}
