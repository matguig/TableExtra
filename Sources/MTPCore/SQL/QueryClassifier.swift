import Foundation

public enum StatementKind: String, Sendable {
    /// Cannot change data (SELECT, SHOW, EXPLAIN without ANALYZE...).
    case read
    /// Changes rows (INSERT, UPDATE, DELETE, MERGE, COPY FROM...).
    case write
    /// Changes structure or permissions (CREATE, ALTER, DROP, TRUNCATE, GRANT...).
    case ddl
    /// BEGIN / COMMIT / ROLLBACK / SAVEPOINT.
    case transaction
    /// SET, RESET, LISTEN... session-level, harmless.
    case session
    case unknown

    public var isWrite: Bool { self == .write || self == .ddl || self == .unknown }
}

public struct StatementAnalysis: Sendable {
    public var kind: StatementKind
    public var verb: String
    /// UPDATE or DELETE without a top-level WHERE clause.
    public var isUnbounded: Bool
    /// DROP, TRUNCATE, ALTER ... DROP, unbounded UPDATE/DELETE.
    public var isDestructive: Bool
    /// Data change that PostgreSQL can execute inside BEGIN … ROLLBACK to count affected rows.
    public var supportsDryRun: Bool
    public var warnings: [String]
    /// Table targeted by INSERT/UPDATE/DELETE/TRUNCATE/DROP TABLE when it can be determined.
    public var targetTable: String?
}

public enum QueryClassifier {
    static let readVerbs: Set<String> = ["SELECT", "SHOW", "VALUES", "TABLE", "DESCRIBE", "DESC", "FETCH"]
    static let writeVerbs: Set<String> = ["INSERT", "UPDATE", "DELETE", "MERGE", "COPY", "REPLACE", "UPSERT", "CALL", "DO", "LOCK", "IMPORT"]
    static let ddlVerbs: Set<String> = ["CREATE", "ALTER", "DROP", "TRUNCATE", "GRANT", "REVOKE", "COMMENT", "REINDEX", "VACUUM",
                                        "CLUSTER", "REFRESH", "RENAME", "ATTACH", "DETACH", "SECURITY", "REASSIGN"]
    static let transactionVerbs: Set<String> = ["BEGIN", "COMMIT", "ROLLBACK", "SAVEPOINT", "RELEASE", "START", "END", "ABORT", "PREPARE"]
    static let sessionVerbs: Set<String> = ["SET", "RESET", "LISTEN", "UNLISTEN", "NOTIFY", "DISCARD", "DEALLOCATE", "CHECKPOINT", "LOAD", "ANALYZE", "ANALYSE"]

    public static func analyze(_ sql: String, driver: DriverKind = .postgres) -> StatementAnalysis {
        let tokens = SQLTokenizer.tokenize(sql).filter { !$0.kind.isTrivia }
        guard let first = tokens.first else {
            return StatementAnalysis(kind: .session, verb: "", isUnbounded: false, isDestructive: false, supportsDryRun: false, warnings: [])
        }
        let verb = first.upper
        var kind: StatementKind = .unknown
        var warnings: [String] = []
        var unbounded = false
        var destructive = false
        var target: String?

        // Top-level words (depth 0) of the statement.
        var depth = 0
        var top: [SQLToken] = []
        var all: [String] = []
        for t in tokens {
            if t.kind == .openParen { depth += 1; continue }
            if t.kind == .closeParen { depth = max(0, depth - 1); continue }
            if t.kind == .keyword || t.kind == .identifier { all.append(t.upper) }
            if depth == 0 { top.append(t) }
        }
        let topWords = top.filter { $0.kind == .keyword || $0.kind == .identifier }.map(\.upper)
        let containsDML = all.contains { ["INSERT", "UPDATE", "DELETE", "MERGE"].contains($0) }

        func nameAfter(_ index: Int) -> String? {
            var j = index + 1
            while j < top.count, ["ONLY", "FROM", "INTO", "TABLE", "IF", "EXISTS", "ONLY"].contains(top[j].upper) { j += 1 }
            guard j < top.count else { return nil }
            var name = top[j].text
            if j + 2 < top.count, top[j + 1].kind == .dot { name += "." + top[j + 2].text }
            return name
        }

        switch verb {
        case _ where readVerbs.contains(verb):
            kind = .read
            if verb == "SELECT", topWords.contains("INTO") { kind = .ddl; warnings.append("SELECT … INTO creates a table") }
        case "WITH":
            if containsDML {
                kind = .write
                if let i = top.firstIndex(where: { ["UPDATE", "DELETE"].contains($0.upper) }) {
                    let tail = top[i...].map(\.upper)
                    if !tail.contains("WHERE") { unbounded = true }
                    target = nameAfter(i)
                }
            } else {
                kind = .read
            }
        case "EXPLAIN":
            let analyzeIndex = all.firstIndex(of: "ANALYZE") ?? all.firstIndex(of: "ANALYSE")
            kind = (analyzeIndex != nil && containsDML) ? .write : .read
            if kind == .write { warnings.append("EXPLAIN ANALYZE executes the statement") }
        case "PRAGMA":
            kind = tokens.contains { $0.kind == .operator && $0.text == "=" } ? .session : .read
        case _ where writeVerbs.contains(verb):
            kind = .write
            if verb == "COPY" && !topWords.contains("FROM") { kind = .read }
            if verb == "UPDATE" || verb == "DELETE" {
                if !topWords.contains("WHERE") {
                    unbounded = true
                    destructive = true
                    warnings.append("\(verb) without WHERE affects every row")
                }
                if verb == "UPDATE" { target = nameAfter(0) } else { target = nameAfter(0) }
            }
            if verb == "INSERT" { target = nameAfter(0) }
        case _ where ddlVerbs.contains(verb):
            kind = .ddl
            if verb == "DROP" { destructive = true; warnings.append("DROP permanently removes objects"); target = nameAfter(1) }
            if verb == "TRUNCATE" { destructive = true; warnings.append("TRUNCATE deletes every row"); target = nameAfter(0) }
            if verb == "ALTER", topWords.contains("DROP") { destructive = true; warnings.append("ALTER … DROP removes structure") }
        case _ where transactionVerbs.contains(verb):
            kind = .transaction
        case _ where sessionVerbs.contains(verb):
            kind = .session
            if verb == "ANALYZE" || verb == "ANALYSE" { kind = .session }
        default:
            kind = .unknown
        }

        let dryRunVerbs: Set<String> = ["INSERT", "UPDATE", "DELETE", "MERGE", "WITH"]
        let supportsDryRun = driver == .postgres && kind == .write && dryRunVerbs.contains(verb)
        return StatementAnalysis(kind: kind, verb: verb, isUnbounded: unbounded, isDestructive: destructive,
                                 supportsDryRun: supportsDryRun, warnings: warnings, targetTable: target)
    }

    /// True if every statement in the script is read-only.
    public static func isReadOnlyScript(_ sql: String, driver: DriverKind = .postgres) -> Bool {
        let statements = StatementSplitter.split(sql)
        return !statements.isEmpty && statements.allSatisfy {
            let k = analyze($0.text, driver: driver).kind
            return k == .read || k == .session
        }
    }
}
