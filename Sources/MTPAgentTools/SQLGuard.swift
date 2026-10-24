import Foundation
import MTPCore

/// Decides what an agent may send. Static checks come first; the database then enforces
/// read-only mode (BEGIN READ ONLY / SQLITE_OPEN_READONLY) as a second line of defence.
enum SQLGuard {
    /// Functions with side effects that a read-only transaction does not stop (or that outlive ROLLBACK).
    static let blockedFunctions: Set<String> = [
        "PG_TERMINATE_BACKEND", "PG_CANCEL_BACKEND", "PG_RELOAD_CONF", "PG_ROTATE_LOGFILE", "PG_SWITCH_WAL", "PG_PROMOTE",
        "PG_CREATE_RESTORE_POINT", "PG_ADVISORY_LOCK", "PG_ADVISORY_LOCK_SHARED", "PG_TRY_ADVISORY_LOCK",
        "PG_TRY_ADVISORY_LOCK_SHARED", "DBLINK", "DBLINK_EXEC", "DBLINK_CONNECT", "DBLINK_SEND_QUERY", "LO_IMPORT", "LO_EXPORT",
        "LO_UNLINK", "PG_FILE_WRITE", "PG_FILE_UNLINK", "PG_FILE_RENAME", "PG_LOGICAL_EMIT_MESSAGE", "SET_CONFIG",
    ]

    /// nil when the script may run through `run_query`, otherwise the reason it is refused.
    static func readOnlyViolation(_ sql: String, driver: DriverKind) -> String? {
        let statements = StatementSplitter.split(sql)
        guard !statements.isEmpty else { return "The SQL is empty." }
        guard QueryClassifier.isReadOnlyScript(sql, driver: driver) else {
            let offending = statements.map { QueryClassifier.analyze($0.text, driver: driver) }
                .first { $0.kind != .read && $0.kind != .session }
            let verb = offending.map { $0.verb.isEmpty ? "statement" : $0.verb } ?? "statement"
            return "run_query only accepts read-only SQL (SELECT, WITH … SELECT, SHOW, VALUES, TABLE, EXPLAIN). "
                + "\(verb) is classified as \(offending?.kind.rawValue ?? "a write"). Use execute_statement for writes, if the connection allows them."
        }
        for s in statements {
            let a = QueryClassifier.analyze(s.text, driver: driver)
            // SET/RESET could lift the READ ONLY transaction mode or change roles; nothing else in "session" is needed here.
            if a.kind != .read { return "run_query does not accept \(a.verb) statements (only reads are allowed)." }
            if a.verb == "COPY" { return "COPY is not available through MCP; use SELECT instead." }
            if driver == .postgres, a.verb == "FETCH" { return "Cursors are not available through MCP." }
            if let f = blockedFunction(in: s.text) { return "The function \(f.lowercased())() has side effects and is not allowed through MCP." }
        }
        return nil
    }

    static func blockedFunction(in sql: String) -> String? {
        let tokens = SQLTokenizer.tokenize(sql).filter { !$0.kind.isTrivia }
        for (i, t) in tokens.enumerated() where t.kind == .identifier || t.kind == .keyword || t.kind == .quotedIdentifier {
            let name = t.kind == .quotedIdentifier ? String(t.text.dropFirst().dropLast()).uppercased() : t.upper
            guard blockedFunctions.contains(name) else { continue }
            if i + 1 < tokens.count, tokens[i + 1].kind == .openParen { return name }
        }
        return nil
    }

    /// explain_query wraps exactly one statement; a second statement would run unexplained.
    static func explainViolation(_ sql: String, driver: DriverKind) -> String? {
        let statements = StatementSplitter.split(sql)
        guard statements.count == 1, let s = statements.first else {
            return statements.isEmpty ? "The SQL is empty." : "explain_query takes exactly one statement (got \(statements.count))."
        }
        let a = QueryClassifier.analyze(s.text, driver: driver)
        if a.verb == "EXPLAIN" { return "Pass the statement itself, without EXPLAIN; explain_query adds it (never with ANALYZE)." }
        if a.kind == .transaction || a.kind == .session { return "\(a.verb) cannot be explained." }
        if let f = blockedFunction(in: s.text) { return "The function \(f.lowercased())() is not allowed through MCP." }
        return nil
    }

    static func explainSQL(_ statement: String, driver: DriverKind) -> String {
        driver == .postgres ? "EXPLAIN (FORMAT TEXT) \(statement)" : "EXPLAIN QUERY PLAN \(statement)"
    }

    static func stripTrailingSemicolon(_ sql: String) -> String {
        var s = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix(";") { s = String(s.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines) }
        return s
    }
}

/// Write policy for execute_statement, shared wording with list_connections.
enum WritePolicy {
    static func refusal(for c: ConnectionConfig) -> String? {
        if c.mcpAccess != .readWrite {
            return "Writes are disabled for agents on “\(c.name)” (MCP access: \(c.mcpAccess.displayName)). Change it in TableExtra → connection settings → MCP access."
        }
        if c.environment == .production || c.environment == .staging {
            return "“\(c.name)” is a \(c.environment.displayName.lowercased()) connection: tableextra-mcp never writes to production or staging. Run the statement yourself in TableExtra."
        }
        if c.safety == .readOnly {
            return "“\(c.name)” is configured read-only in TableExtra; writes are blocked."
        }
        if c.safety == .protectedWrites {
            return "“\(c.name)” requires Touch ID for every write, which an agent cannot provide. Run the statement yourself in TableExtra."
        }
        return nil
    }

    static func summary(for c: ConnectionConfig) -> String {
        refusal(for: c) == nil ? "read-write" : "read-only"
    }
}
