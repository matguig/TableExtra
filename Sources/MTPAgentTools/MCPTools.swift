import Foundation
import MTPCore

public struct ToolResult: Sendable {
    public var text: String
    public var isError: Bool

    public init(text: String, isError: Bool) {
        self.text = text
        self.isError = isError
    }

    var json: JSONValue {
        ["content": [["type": "text", "text": .string(text)]], "isError": .bool(isError)]
    }
}

enum ToolFailure: Error {
    /// The request is understood but not allowed (policy, read-only, production).
    case refused(String)
    /// Missing or malformed arguments; reported as a tool error so the agent can correct itself.
    case invalid(String)
}

/// What a call touched, for the audit log and the app history.
final class CallRecord: @unchecked Sendable {
    var connection: ConnectionConfig?
    var sql: String?
    var outcome = ""
    var rowCount: Int?
}

public final class MCPTools: @unchecked Sendable {
    static let maxRowsLimit = 5000
    static let defaultMaxRows = 200
    static let searchLimit = 200

    let environment: MCPEnvironment
    let pool: ClientPool
    private let lock = NSLock()
    private var _clientName: String?

    public init(environment: MCPEnvironment) {
        self.environment = environment
        self.pool = ClientPool(secrets: environment.secrets)
    }

    /// MCP client name from `initialize` (e.g. "claude-code"), stored in the audit log.
    public var clientName: String? {
        get { lock.lock(); defer { lock.unlock() }; return _clientName }
        set { lock.lock(); _clientName = newValue; lock.unlock() }
    }

    public func shutdown() { pool.closeAll() }

    // MARK: Definitions

    static let names: [String] = ["list_connections", "list_schemas", "list_tables", "describe_table", "search_schema",
                                  "run_query", "explain_query", "execute_statement"]

    public static var definitions: [JSONValue] {
        let connection: JSONValue = ["type": "string", "description": "Connection name or id, as returned by list_connections."]
        let schema: JSONValue = ["type": "string", "description": "Schema name. Defaults to the connection's default schema (public / main)."]
        func tool(_ name: String, _ title: String, _ description: String, _ properties: [String: JSONValue], required: [String],
                  readOnly: Bool = true, destructive: Bool = false) -> JSONValue {
            [
                "name": .string(name),
                "title": .string(title),
                "description": .string(description),
                "inputSchema": [
                    "type": "object",
                    "properties": .object(properties),
                    "required": .array(required.map { .string($0) }),
                    "additionalProperties": false,
                ],
                "annotations": [
                    "title": .string(title),
                    "readOnlyHint": .bool(readOnly),
                    "destructiveHint": .bool(destructive),
                    "idempotentHint": .bool(readOnly),
                    "openWorldHint": false,
                ],
            ]
        }
        return [
            tool("list_connections", "List connections",
                 "Lists the database connections saved in TableExtra that are shared with agents: name, id, driver, environment (local, development, staging, production…) and whether agents may write. Call this first.",
                 [:], required: []),
            tool("list_schemas", "List schemas", "Lists the schemas of a connection (PostgreSQL schemas, SQLite attached databases).",
                 ["connection": connection], required: ["connection"]),
            tool("list_tables", "List tables",
                 "Lists tables, views and materialized views of a schema with kind, estimated row count, size and comment, plus functions and enum types.",
                 ["connection": connection, "schema": schema], required: ["connection"]),
            tool("describe_table", "Describe table",
                 "Describes one table or view: columns (type, nullability, default), primary key, foreign keys, referencing tables, indexes, constraints, triggers and enum values.",
                 ["connection": connection,
                  "table": ["type": "string", "description": "Table or view name; \"schema.table\" is accepted."],
                  "schema": schema],
                 required: ["connection", "table"]),
            tool("search_schema", "Search schema",
                 "Finds tables and columns whose name matches a pattern (case-insensitive substring; % and * are wildcards) across all user schemas.",
                 ["connection": connection,
                  "pattern": ["type": "string", "description": "Text to look for in table and column names, e.g. \"customer\" or \"created_%\"."],
                  "schema": ["type": "string", "description": "Limit the search to one schema."]],
                 required: ["connection", "pattern"]),
            tool("run_query", "Run read-only query",
                 "Runs read-only SQL (SELECT, WITH … SELECT, SHOW, VALUES, EXPLAIN) and returns the rows as a text table. PostgreSQL queries run inside BEGIN READ ONLY with a 30 s statement timeout and are always rolled back; SQLite files are opened read-only. Writes are refused: use execute_statement.",
                 ["connection": connection,
                  "sql": ["type": "string", "description": "The SQL to run. Several read-only statements separated by ; are allowed; the last result set is returned."],
                  "max_rows": ["type": "integer", "description": "Maximum rows to return (default 200, at most 5000).", "minimum": 1, "maximum": .int(maxRowsLimit), "default": .int(defaultMaxRows)],
                  "format": ["type": "string", "enum": ["table", "csv"], "description": "Output format (default table).", "default": "table"]],
                 required: ["connection", "sql"]),
            tool("explain_query", "Explain query",
                 "Shows the planner's execution plan for one statement (PostgreSQL EXPLAIN (FORMAT TEXT), SQLite EXPLAIN QUERY PLAN). The statement is not executed (no ANALYZE).",
                 ["connection": connection, "sql": ["type": "string", "description": "One statement, without EXPLAIN."]],
                 required: ["connection", "sql"]),
            tool("execute_statement", "Execute write statement",
                 "Executes INSERT / UPDATE / DELETE / DDL in one transaction and returns the affected rows. Only allowed on connections whose MCP access is “Read & write”, never on production or staging, never on read-only connections. DROP, TRUNCATE and UPDATE/DELETE without WHERE also need confirm_destructive: true.",
                 ["connection": connection,
                  "sql": ["type": "string", "description": "One or more statements separated by ;. Do not include BEGIN/COMMIT."],
                  "confirm_destructive": ["type": "boolean", "description": "Set to true to run DROP, TRUNCATE or UPDATE/DELETE without WHERE.", "default": false]],
                 required: ["connection", "sql"], readOnly: false, destructive: true),
        ]
    }

    // MARK: Dispatch

    public func call(_ name: String, arguments: [String: JSONValue]) async -> ToolResult {
        let start = Date()
        let record = CallRecord()
        var status = "ok"
        let result: ToolResult
        do {
            let text = try await run(name, arguments, record)
            result = ToolResult(text: text, isError: false)
            if record.outcome.isEmpty { record.outcome = "ok" }
        } catch let failure as ToolFailure {
            switch failure {
            case .refused(let message):
                status = "refused"
                record.outcome = message
                result = ToolResult(text: "Refused: \(message)", isError: true)
            case .invalid(let message):
                status = "error"
                record.outcome = "invalid arguments: \(message)"
                result = ToolResult(text: message, isError: true)
            }
        } catch let error as DatabaseError {
            status = "error"
            let cancelled = Task.isCancelled
            record.outcome = cancelled ? "cancelled by client" : error.message
            result = ToolResult(text: Self.describe(error, sql: record.sql), isError: true)
        } catch is CancellationError {
            status = "error"
            record.outcome = "cancelled by client"
            result = ToolResult(text: "Cancelled.", isError: true)
        } catch {
            status = "error"
            record.outcome = error.localizedDescription
            result = ToolResult(text: error.localizedDescription, isError: true)
        }
        let duration = Date().timeIntervalSince(start)
        environment.audit.append(AuditEntry(ts: AuditLog.timestamp(start), tool: name, connection: record.connection?.name,
                                            sql: record.sql, status: status, outcome: record.outcome,
                                            duration_ms: Int((duration * 1000).rounded()), client: clientName))
        if let c = record.connection, let sql = record.sql, let history = environment.history {
            let database = c.driver == .sqlite ? (c.filePath as NSString).lastPathComponent : c.database
            history.add(connectionID: c.id, database: database, sql: sql, duration: duration, rowCount: record.rowCount,
                        error: status == "ok" ? nil : (status == "refused" ? "Refused by tableextra-mcp: \(record.outcome)" : record.outcome),
                        source: environment.historySource, at: start)
            history.flush()
        }
        return result
    }

    private func run(_ name: String, _ args: [String: JSONValue], _ record: CallRecord) async throws -> String {
        switch name {
        case "list_connections": return listConnections(record)
        case "list_schemas": return try await listSchemas(args, record)
        case "list_tables": return try await listTables(args, record)
        case "describe_table": return try await describeTable(args, record)
        case "search_schema": return try await searchSchema(args, record)
        case "run_query": return try await runQuery(args, record)
        case "explain_query": return try await explainQuery(args, record)
        case "execute_statement": return try await executeStatement(args, record)
        default: throw ToolFailure.invalid("Unknown tool \(name)")
        }
    }

    // MARK: Arguments

    func visibleConnections() -> [ConnectionConfig] {
        environment.connections().filter { $0.mcpAccess != .none }
    }

    func resolve(_ args: [String: JSONValue], _ record: CallRecord) throws -> ConnectionConfig {
        guard let key = string(args, "connection") else {
            throw ToolFailure.invalid("Missing required argument `connection` (a name or id from list_connections).")
        }
        let visible = visibleConnections()
        let match: ConnectionConfig?
        if let id = UUID(uuidString: key), let c = visible.first(where: { $0.id == id }) {
            match = c
        } else {
            match = visible.first { $0.name == key } ?? visible.first { $0.name.caseInsensitiveCompare(key) == .orderedSame }
        }
        guard let c = match else {
            let names = visible.map { "“\($0.name)”" }.sorted().joined(separator: ", ")
            throw ToolFailure.invalid("No connection “\(key)” is shared with agents. Available: \(names.isEmpty ? "none" : names).")
        }
        record.connection = c
        return c
    }

    func string(_ args: [String: JSONValue], _ key: String) -> String? {
        guard let v = args[key] else { return nil }
        let s: String?
        switch v {
        case .string(let x): s = x
        case .int(let i): s = String(i)
        default: s = nil
        }
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    func requiredSQL(_ args: [String: JSONValue], _ record: CallRecord) throws -> String {
        guard let sql = string(args, "sql") else { throw ToolFailure.invalid("Missing required argument `sql`.") }
        record.sql = sql
        return sql
    }

    // MARK: Tools

    func listConnections(_ record: CallRecord) -> String {
        let visible = visibleConnections().sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        record.outcome = "\(visible.count) connections"
        guard !visible.isEmpty else {
            return "No connection is shared with agents. In TableExtra, open a connection's settings and set “MCP access” to Read-only or Read & write."
        }
        let rows: [[String?]] = visible.map { c in
            [c.name, c.id.uuidString, c.driver.displayName, c.environment.rawValue, Self.accessLabel(c),
             c.driver == .sqlite ? (c.filePath as NSString).lastPathComponent : (c.database.isEmpty ? c.user : c.database)]
        }
        return TextTable.render(headers: ["name", "id", "driver", "environment", "agent access", "database"], rows: rows)
            + "\n\nUse the name or the id as `connection` in the other tools. run_query is always read-only; execute_statement needs agent access = read-write."
    }

    static func accessLabel(_ c: ConnectionConfig) -> String {
        if WritePolicy.refusal(for: c) == nil { return "read-write" }
        if c.mcpAccess == .readWrite {
            if c.environment == .production || c.environment == .staging { return "read-only (\(c.environment.rawValue))" }
            if c.safety == .readOnly { return "read-only (read-only connection)" }
            if c.safety == .protectedWrites { return "read-only (Touch ID writes)" }
        }
        return "read-only"
    }

    func listSchemas(_ args: [String: JSONValue], _ record: CallRecord) async throws -> String {
        let c = try resolve(args, record)
        let client = pool.client(for: c, readOnly: true)
        let intro = Introspection.make(client)
        let schemas = try await cancellable(client) { try await intro.schemas(includeSystem: false) }
        let current = (try? await intro.defaultSchema()) ?? ""
        record.outcome = "\(schemas.count) schemas"
        let lines = schemas.map { $0 == current ? "\($0) (default)" : $0 }
        return "Schemas of “\(c.name)”:\n" + lines.joined(separator: "\n")
    }

    func defaultSchema(_ c: ConnectionConfig, _ intro: SchemaIntrospector) async -> String {
        if let s = c.defaultSchema, !s.isEmpty { return s }
        if let s = try? await intro.defaultSchema(), !s.isEmpty { return s }
        return c.driver == .sqlite ? "main" : "public"
    }

    func listTables(_ args: [String: JSONValue], _ record: CallRecord) async throws -> String {
        let c = try resolve(args, record)
        let client = pool.client(for: c, readOnly: true)
        let intro = Introspection.make(client)
        var schema = string(args, "schema")
        if schema == nil { schema = await defaultSchema(c, intro) }
        let objects = try await cancellable(client) { try await intro.objects(in: schema!) }
        let relations = objects.filter(\.kind.hasData)
        record.outcome = "\(relations.count) relations"
        var out = "Schema \(schema!) of “\(c.name)”: \(relations.count) tables and views\n\n"
        if relations.isEmpty {
            out += "(none — check the schema name with list_schemas)"
        } else {
            let rows: [[String?]] = relations.map { o in
                let rows = o.kind == .view ? nil : o.estimatedRows
                return [o.name, Self.kindName(o.kind), rows.map { "~\($0)" } ?? "", o.sizeBytes.map(Self.bytes) ?? "", o.comment ?? ""]
            }
            out += TextTable.render(headers: ["name", "kind", "rows (est.)", "size", "comment"], rows: rows)
        }
        let functions = objects.filter { $0.kind == .function || $0.kind == .procedure }
        if !functions.isEmpty {
            out += "\n\nFunctions: " + functions.prefix(100).map { $0.signature ?? $0.name }.joined(separator: ", ")
            if functions.count > 100 { out += ", … (\(functions.count - 100) more)" }
        }
        let types = objects.filter { $0.kind == .type }
        if !types.isEmpty { out += "\nTypes: " + types.map(\.name).joined(separator: ", ") }
        return out
    }

    static func kindName(_ k: DBObjectKind) -> String {
        switch k {
        case .table: return "table"
        case .view: return "view"
        case .materializedView: return "materialized view"
        case .foreignTable: return "foreign table"
        case .function: return "function"
        case .procedure: return "procedure"
        case .sequence: return "sequence"
        case .type: return "type"
        }
    }

    /// Locale-independent (agents parse it): 512 B, 16.0 KiB, 2.3 MiB.
    static func bytes(_ n: Int64) -> String {
        let units = ["B", "KiB", "MiB", "GiB", "TiB"]
        var v = Double(n)
        var i = 0
        while v >= 1024, i < units.count - 1 { v /= 1024; i += 1 }
        return i == 0 ? "\(n) B" : String(format: "%.1f %@", v, units[i])
    }

    /// "public.orders", "\"Mixed\".\"Case\"" → (schema, name).
    static func splitQualified(_ s: String) -> (String?, String) {
        let tokens = SQLTokenizer.tokenize(s).filter { !$0.kind.isTrivia }
        func unquote(_ t: SQLToken) -> String {
            t.kind == .quotedIdentifier ? String(t.text.dropFirst().dropLast()).replacingOccurrences(of: "\"\"", with: "\"") : t.text
        }
        if tokens.count == 3, tokens[1].kind == .dot { return (unquote(tokens[0]), unquote(tokens[2])) }
        if tokens.count == 1 { return (nil, unquote(tokens[0])) }
        return (nil, s)
    }

    func describeTable(_ args: [String: JSONValue], _ record: CallRecord) async throws -> String {
        let c = try resolve(args, record)
        guard let raw = string(args, "table") else { throw ToolFailure.invalid("Missing required argument `table`.") }
        let client = pool.client(for: c, readOnly: true)
        let intro = Introspection.make(client)
        var (schema, name) = Self.splitQualified(raw)
        if let s = string(args, "schema") { schema = s }
        let explicitSchema = schema != nil
        let searchSchema: String
        if let schema { searchSchema = schema } else { searchSchema = await defaultSchema(c, intro) }

        var details: TableDetails?
        do {
            details = try await cancellable(client) { try await intro.tableDetails(schema: searchSchema, name: name) }
        } catch let e as DatabaseError where !e.isCancellation {
            // Wrong case or wrong schema: look the name up before giving up.
            var candidates: [DBObject] = []
            let schemas = explicitSchema ? [searchSchema] : ((try? await intro.schemas(includeSystem: false)) ?? [searchSchema])
            for s in schemas {
                candidates += ((try? await intro.objects(in: s)) ?? []).filter(\.kind.hasData)
            }
            if let hit = candidates.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame && $0.schema == searchSchema })
                ?? candidates.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                details = try await cancellable(client) { try await intro.tableDetails(schema: hit.schema, name: hit.name) }
            } else {
                let similar = candidates.filter { $0.name.localizedCaseInsensitiveContains(name) || name.localizedCaseInsensitiveContains($0.name) }
                    .prefix(10).map(\.qualifiedName)
                throw ToolFailure.invalid("Table “\(raw)” not found in \(explicitSchema ? "schema \(searchSchema)" : "any schema")."
                    + (similar.isEmpty ? " Use list_tables or search_schema." : " Did you mean: \(similar.joined(separator: ", "))?"))
            }
        }
        guard let t = details else { throw ToolFailure.invalid("Table “\(raw)” not found.") }
        var referencedBy: [String] = []
        if c.driver == .postgres {
            let q = client.dialect.qualified(schema: t.object.schema, name: t.object.name)
            if let r = try? await client.query("""
                SELECT n.nspname, c.relname, con.conname,
                       array_to_string(ARRAY(SELECT a.attname FROM unnest(con.conkey) WITH ORDINALITY k(attnum, ord)
                         JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.attnum ORDER BY k.ord), ', ')
                FROM pg_constraint con
                JOIN pg_class c ON c.oid = con.conrelid
                JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE con.contype = 'f' AND con.confrelid = $1::regclass
                ORDER BY 1, 2, 3
                """, [q]) {
                referencedBy = r.rows.map { "\($0[0] ?? "").\($0[1] ?? "")(\($0[3] ?? "")) via \($0[2] ?? "")" }
            }
        }
        record.outcome = "\(t.object.qualifiedName): \(t.columns.count) columns"
        return Self.describe(t, referencedBy: referencedBy)
    }

    static func describe(_ t: TableDetails, referencedBy: [String]) -> String {
        var out = "\(t.object.qualifiedName) — \(kindName(t.object.kind))"
        if let n = t.object.estimatedRows { out += ", ~\(n) rows (estimate)" }
        if let comment = t.object.comment, !comment.isEmpty { out += "\nComment: \(comment)" }
        let rows: [[String?]] = t.columns.map { col in
            var key: [String] = []
            if col.isPrimaryKey { key.append("PK") }
            if let fk = col.foreignKey {
                let i = fk.columns.firstIndex(of: col.name) ?? 0
                key.append("FK → \(fk.refSchema.isEmpty ? "" : fk.refSchema + ".")\(fk.refTable)(\(i < fk.refColumns.count ? fk.refColumns[i] : fk.refColumns.joined(separator: ",")))")
            }
            var notes: [String] = []
            if col.isIdentity { notes.append("identity") }
            if col.isGenerated { notes.append("generated") }
            if let e = col.enumValues { notes.append("enum: " + e.joined(separator: ", ")) }
            if let cm = col.comment, !cm.isEmpty { notes.append(cm) }
            return [col.name, col.dataType, col.isNullable ? "null" : "not null", col.defaultValue ?? "", key.joined(separator: " "),
                    notes.joined(separator: "; ")]
        }
        out += "\n\nColumns:\n" + TextTable.render(headers: ["column", "type", "nullable", "default", "key", "notes"], rows: rows)
        if !t.primaryKey.isEmpty { out += "\n\nPrimary key: (\(t.primaryKey.joined(separator: ", ")))" }
        if !t.foreignKeys.isEmpty {
            out += "\n\nForeign keys:"
            for fk in t.foreignKeys {
                var line = "\n  \(fk.constraintName): (\(fk.columns.joined(separator: ", "))) → \(fk.refSchema.isEmpty ? "" : fk.refSchema + ".")\(fk.refTable)(\(fk.refColumns.joined(separator: ", ")))"
                if let d = fk.onDelete, d != "NO ACTION" { line += " ON DELETE \(d)" }
                if let u = fk.onUpdate, u != "NO ACTION" { line += " ON UPDATE \(u)" }
                out += line
            }
        }
        if !referencedBy.isEmpty { out += "\n\nReferenced by:\n" + referencedBy.map { "  \($0)" }.joined(separator: "\n") }
        let other = t.constraints.filter { $0.kind == .unique || $0.kind == .check || $0.kind == .exclusion }
        if !other.isEmpty {
            out += "\n\nConstraints:\n" + other.map { "  \($0.name): \($0.definition)" }.joined(separator: "\n")
        }
        if !t.indexes.isEmpty {
            out += "\n\nIndexes:\n" + t.indexes.map { i in
                let def = i.definition.isEmpty ? "\(i.isUnique ? "UNIQUE " : "")(\(i.columns.joined(separator: ", ")))" : i.definition
                return "  \(i.name): \(def)"
            }.joined(separator: "\n")
        }
        if !t.triggers.isEmpty {
            out += "\n\nTriggers:\n" + t.triggers.map { "  \($0.name): \($0.timing) \($0.events)\($0.isEnabled ? "" : " (disabled)")" }.joined(separator: "\n")
        }
        return out
    }

    /// "customer" → "%customer%"; "created_*" → "created_%"; explicit % kept.
    static func likePattern(_ p: String) -> String {
        let s = p.replacingOccurrences(of: "*", with: "%")
        return s.contains("%") ? s : "%\(s)%"
    }

    static func likeRegex(_ like: String) -> NSRegularExpression? {
        var pattern = "^"
        for ch in like {
            switch ch {
            case "%": pattern += ".*"
            case "_": pattern += "."
            default: pattern += NSRegularExpression.escapedPattern(for: String(ch))
            }
        }
        pattern += "$"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }

    func searchSchema(_ args: [String: JSONValue], _ record: CallRecord) async throws -> String {
        let c = try resolve(args, record)
        guard let pattern = string(args, "pattern") else { throw ToolFailure.invalid("Missing required argument `pattern`.") }
        let like = Self.likePattern(pattern)
        let onlySchema = string(args, "schema")
        let client = pool.client(for: c, readOnly: true)
        var tables: [String] = []
        var columns: [String] = []
        let limit = Self.searchLimit

        switch c.driver {
        case .postgres:
            let filter = onlySchema != nil ? "n.nspname = $2" : "n.nspname NOT LIKE 'pg\\_%' AND n.nspname <> 'information_schema'"
            let params: [String?] = onlySchema != nil ? [like, onlySchema] : [like]
            let t = try await cancellable(client) {
                try await client.query("""
                    SELECT n.nspname, c.relname, c.relkind FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                    WHERE c.relkind IN ('r','p','v','m','f') AND \(filter) AND c.relname ILIKE $1
                    ORDER BY n.nspname = 'public' DESC, 1, 2 LIMIT \(limit + 1)
                    """, params)
            }
            tables = t.rows.map { r in
                let kind: String
                switch r[2] { case "v": kind = "view"; case "m": kind = "materialized view"; case "f": kind = "foreign table"; default: kind = "table" }
                return "\(r[0] ?? "").\(r[1] ?? "") (\(kind))"
            }
            let col = try await cancellable(client) {
                try await client.query("""
                    SELECT n.nspname, c.relname, a.attname, format_type(a.atttypid, a.atttypmod)
                    FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
                    WHERE c.relkind IN ('r','p','v','m','f') AND a.attnum > 0 AND NOT a.attisdropped AND \(filter) AND a.attname ILIKE $1
                    ORDER BY n.nspname = 'public' DESC, 1, 2, a.attnum LIMIT \(limit + 1)
                    """, params)
            }
            columns = col.rows.map { "\($0[0] ?? "").\($0[1] ?? "").\($0[2] ?? "") \($0[3] ?? "")" }
        case .sqlite:
            guard let regex = Self.likeRegex(like) else { throw ToolFailure.invalid("Invalid pattern.") }
            func matches(_ s: String) -> Bool { regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
            let intro = Introspection.make(client)
            let schemas: [String]
            if let onlySchema { schemas = [onlySchema] } else { schemas = try await intro.schemas(includeSystem: false) }
            for s in schemas {
                for o in try await intro.objects(in: s) where o.kind.hasData && matches(o.name) {
                    tables.append("\(o.qualifiedName) (\(Self.kindName(o.kind)))")
                }
                for (table, cols) in try await intro.columnsByTable(schema: s).sorted(by: { $0.key < $1.key }) {
                    for col in cols where matches(col.name) { columns.append("\(s).\(table).\(col.name) \(col.dataType)") }
                }
            }
        }
        record.outcome = "\(tables.count) tables, \(columns.count) columns"
        func section(_ title: String, _ items: [String]) -> String {
            if items.isEmpty { return "\(title): none" }
            let shown = items.prefix(limit)
            return "\(title) (\(items.count > limit ? "first \(limit)" : String(items.count))):\n" + shown.map { "  \($0)" }.joined(separator: "\n")
        }
        return "Matches for “\(pattern)” in “\(c.name)”:\n\n" + section("Tables", tables) + "\n\n" + section("Columns", columns)
    }

    func runQuery(_ args: [String: JSONValue], _ record: CallRecord) async throws -> String {
        let c = try resolve(args, record)
        let sql = try requiredSQL(args, record)
        if let reason = SQLGuard.readOnlyViolation(sql, driver: c.driver) { throw ToolFailure.refused(reason) }
        var maxRows = Self.defaultMaxRows
        if let v = args["max_rows"], !v.isNull {
            guard let n = v.intValue, n >= 1 else { throw ToolFailure.invalid("max_rows must be a positive integer.") }
            maxRows = min(n, Self.maxRowsLimit)
        }
        let format = string(args, "format")?.lowercased() ?? "table"
        guard format == "table" || format == "csv" else { throw ToolFailure.invalid("format must be \"table\" or \"csv\".") }

        var r = try await readOnly(c, sql, maxRows: maxRows + 1)
        if r.rows.count > maxRows {
            r.rows = Array(r.rows.prefix(maxRows))
            r.isTruncated = true
        } else {
            r.isTruncated = false
        }
        record.rowCount = r.hasRows ? r.rows.count : r.affectedRows
        record.outcome = r.hasRows ? "\(r.rows.count) rows\(r.isTruncated ? " (truncated)" : "")" : (r.commandTag.isEmpty ? "ok" : r.commandTag)
        return TextTable.result(r, maxRows: maxRows, format: format)
    }

    func explainQuery(_ args: [String: JSONValue], _ record: CallRecord) async throws -> String {
        let c = try resolve(args, record)
        let sql = try requiredSQL(args, record)
        if let reason = SQLGuard.explainViolation(sql, driver: c.driver) { throw ToolFailure.refused(reason) }
        let statement = SQLGuard.stripTrailingSemicolon(StatementSplitter.split(sql)[0].text)
        let explain = SQLGuard.explainSQL(statement, driver: c.driver)
        record.sql = explain
        let r = try await readOnly(c, explain, maxRows: nil)
        record.outcome = "plan: \(r.rows.count) lines"
        switch c.driver {
        case .postgres:
            return r.rows.map { $0.first.flatMap { $0 } ?? "" }.joined(separator: "\n")
        case .sqlite:
            // id, parent, notused, detail → indented tree.
            var depth: [String: Int] = ["0": -1]
            var lines: [String] = ["QUERY PLAN"]
            for row in r.rows {
                let id = row.first.flatMap { $0 } ?? ""
                let parent = row.count > 1 ? (row[1] ?? "0") : "0"
                let d = (depth[parent] ?? -1) + 1
                depth[id] = d
                lines.append(String(repeating: "  ", count: d) + "`--" + (row.last.flatMap { $0 } ?? ""))
            }
            return lines.joined(separator: "\n")
        }
    }

    func executeStatement(_ args: [String: JSONValue], _ record: CallRecord) async throws -> String {
        let c = try resolve(args, record)
        let sql = try requiredSQL(args, record)
        if let reason = WritePolicy.refusal(for: c) { throw ToolFailure.refused(reason) }
        let statements = StatementSplitter.split(sql)
        guard !statements.isEmpty else { throw ToolFailure.invalid("The SQL is empty.") }
        let analyses = statements.map { QueryClassifier.analyze($0.text, driver: c.driver) }
        if let t = analyses.first(where: { $0.kind == .transaction }) {
            throw ToolFailure.refused("execute_statement wraps the statements in its own transaction; remove \(t.verb).")
        }
        let confirmed = args["confirm_destructive"]?.boolValue ?? false
        let risky = analyses.filter { $0.isUnbounded ? c.guardUnboundedWrites : $0.isDestructive }
        if !risky.isEmpty && !confirmed {
            let why = risky.flatMap(\.warnings)
            throw ToolFailure.refused("destructive statement (\(why.isEmpty ? risky.map(\.verb).joined(separator: ", ") : why.joined(separator: "; "))). "
                + "Check it with the user, then call again with confirm_destructive: true.")
        }

        let client = pool.client(for: c, readOnly: false)
        let timeout = environment.writeTimeout
        let results: [QueryResult] = try await cancellable(client) {
            try await client.perform { d in
                if d.inTransaction { Self.rollback(d) }
                _ = try d.execute("BEGIN", params: [], maxRows: nil)
                do {
                    if d.kind == .postgres { _ = try d.execute("SET LOCAL statement_timeout = '\(timeout)'", params: [], maxRows: nil) }
                    var out: [QueryResult] = []
                    for s in statements { out.append(try d.execute(s.text, params: [], maxRows: nil)) }
                    _ = try d.execute("COMMIT", params: [], maxRows: nil)
                    return out
                } catch {
                    Self.rollback(d)
                    throw error
                }
            }
        }
        let total = results.compactMap(Self.affectedRows).reduce(0, +)
        record.rowCount = total
        record.outcome = "committed \(results.count) statement\(results.count == 1 ? "" : "s"), \(total) rows affected"
        var out = "Committed \(results.count) statement\(results.count == 1 ? "" : "s") on “\(c.name)” in one transaction."
        for (i, r) in results.enumerated() {
            out += "\n\(i + 1). \(r.commandTag.isEmpty ? analyses[i].verb : r.commandTag)"
            if let a = Self.affectedRows(r) { out += " — \(a) row\(a == 1 ? "" : "s") affected" }
            if r.hasRows {
                let table = TextTable.render(headers: r.columns.map(\.name), rows: Array(r.rows.prefix(50)), maxChars: 20_000)
                out += "\n" + table.split(separator: "\n", omittingEmptySubsequences: false).map { "   " + $0 }.joined(separator: "\n")
                if r.rows.count > 50 { out += "\n   … \(r.rows.count - 50) more rows not shown" }
            }
        }
        out += "\nTotal rows affected: \(total)"
        return out
    }

    // MARK: Execution helpers

    /// PostgreSQL reports RETURNING statements as row sets; the count is still in the command tag.
    static func affectedRows(_ r: QueryResult) -> Int? {
        if let a = r.affectedRows { return a }
        let parts = r.commandTag.split(separator: " ")
        guard let verb = parts.first, ["INSERT", "UPDATE", "DELETE", "MERGE", "COPY"].contains(verb.uppercased()),
              let last = parts.last else { return nil }
        return Int(last)
    }

    /// PostgreSQL: BEGIN READ ONLY + statement_timeout, always rolled back. SQLite: read-only handle + watchdog.
    func readOnly(_ c: ConnectionConfig, _ sql: String, maxRows: Int?) async throws -> QueryResult {
        let client = pool.client(for: c, readOnly: true)
        let timeout = environment.statementTimeout
        switch c.driver {
        case .postgres:
            let warmup = pool.needsTypeWarmup(client)
            return try await cancellable(client) {
                try await client.perform { d in
                    if d.inTransaction { Self.rollback(d) }
                    if warmup {
                        _ = try d.execute("SELECT NULL::xid", params: [], maxRows: nil)
                        self.pool.markWarm(client)
                    }
                    _ = try d.execute("BEGIN READ ONLY", params: [], maxRows: nil)
                    defer { Self.rollback(d) }
                    _ = try d.execute("SET LOCAL statement_timeout = '\(timeout)'", params: [], maxRows: nil)
                    return try d.execute(sql, params: [], maxRows: maxRows)
                }
            }
        case .sqlite:
            let seconds = Double(timeout.filter(\.isNumber)) ?? 30
            let watchdog = DispatchWorkItem { client.cancel() }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: watchdog)
            defer { watchdog.cancel() }
            return try await cancellable(client) { try await client.query(sql, maxRows: maxRows) }
        }
    }

    static func rollback(_ d: DatabaseDriver) {
        for _ in 0..<2 where d.inTransaction { _ = try? d.execute("ROLLBACK", params: [], maxRows: nil) }
        if d.inTransaction { try? d.reconnect() }
    }

    func cancellable<T>(_ client: DBClient, _ body: () async throws -> T) async throws -> T {
        try await withTaskCancellationHandler {
            try await body()
        } onCancel: {
            client.cancel()
        }
    }

    static func describe(_ e: DatabaseError, sql: String?) -> String {
        var out = e.fullMessage
        if let state = e.sqlState, !state.hasPrefix("SQLITE") { out += "\nSQLSTATE: \(state)" }
        if let pos = e.position, let sql, pos > 0, pos <= sql.count {
            let idx = sql.index(sql.startIndex, offsetBy: pos - 1)
            let lineStart = sql[..<idx].lastIndex(of: "\n").map { sql.index(after: $0) } ?? sql.startIndex
            let lineEnd = sql[idx...].firstIndex(of: "\n") ?? sql.endIndex
            let line = String(sql[lineStart..<lineEnd])
            let column = sql.distance(from: lineStart, to: idx)
            out += "\n\(line)\n\(String(repeating: " ", count: column))^"
        }
        return out
    }
}
