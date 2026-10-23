import Foundation
import MTPCore
import MTPUIKit

public struct AIAnswer: Sendable, Equatable {
    /// Full markdown answer.
    public var text: String
    /// Content of the ```sql block, when there is one.
    public var sql: String?
    public var model: String?
    public var durationMS: Int?
}

/// One previous message, replayed so follow-up questions have context.
public struct AIChatTurn: Sendable {
    public var isUser: Bool
    public var text: String
    public init(isUser: Bool, text: String) { self.isUser = isUser; self.text = text }
}

public enum AITask: Sendable, Equatable {
    case generate(question: String, currentSQL: String?)
    case explain(sql: String)
    case optimize(sql: String, plan: String?)
    case fix(sql: String, error: String)
    /// Free question from any screen, with that screen's context attached.
    case custom(title: String, prompt: String, attachments: [AIAttachment], focus: String)

    public var title: String {
        switch self {
        case .generate: return "Write SQL"
        case .explain: return "Explain"
        case .optimize: return "Optimize"
        case .fix: return "Fix error"
        case .custom(let title, _, _, _): return title
        }
    }

    /// Text used to pick the tables worth describing first.
    var focusText: String {
        switch self {
        case .generate(let q, let sql): return q + "\n" + (sql ?? "")
        case .explain(let sql), .optimize(let sql, _): return sql
        case .fix(let sql, let error): return sql + "\n" + error
        case .custom(_, let prompt, let attachments, let focus): return [prompt, focus, attachments.map(\.title).joined(separator: " ")].joined(separator: "\n")
        }
    }
}

public extension AIService {
    @MainActor
    static func generateSQL(question: String, context: WorkspaceContext, currentSQL: String?, model: String? = nil) async throws -> AIAnswer {
        try await ask(.generate(question: question, currentSQL: currentSQL), context: context, model: model)
    }

    @MainActor
    static func explain(sql: String, context: WorkspaceContext, model: String? = nil) async throws -> AIAnswer {
        try await ask(.explain(sql: sql), context: context, model: model)
    }

    /// `plan`: EXPLAIN output when the caller already has one.
    @MainActor
    static func optimize(sql: String, context: WorkspaceContext, plan: String?, model: String? = nil) async throws -> AIAnswer {
        try await ask(.optimize(sql: sql, plan: plan), context: context, model: model)
    }

    @MainActor
    static func ask(_ task: AITask, context: WorkspaceContext, model: String? = nil, history: [AIChatTurn] = [],
                    useTools: Bool = true) async throws -> AIAnswer {
        let schemaText = await schemaContext(for: context, focus: task.focusText)
        let dialect = context.connection.driver.displayName
        let access = useTools ? access(for: context.connection) : .none
        var prompt = userPrompt(task, schemaContext: schemaText, dialect: dialect)
        if !history.isEmpty { prompt = conversation(history) + "\n\n" + prompt }
        let system = systemPrompt(dialect: dialect) + accessPrompt(access, connection: context.connection, database: context.currentDatabase)
        let cli = try await Task.detached { try ClaudeCLI.resolved() }.value
        let response = try await cli.ask(prompt, model: model ?? AISettings.defaultModel, systemPrompt: system, access: access)
        return AIAnswer(text: response.text, sql: extractSQL(from: response.text), model: response.model, durationMS: response.durationMS)
    }

    /// What Claude may use besides the prompt: the connection's code repository and, when allowed, read-only queries.
    @MainActor
    public static func access(for connection: ConnectionConfig) -> ClaudeCLI.Access {
        var access = ClaudeCLI.Access(codeRepository: connection.codeRepositoryURL)
        let binary = MCPInstaller.binaryURL()
        if connection.effectiveClaudeCanQuery, FileManager.default.isExecutableFile(atPath: binary.path) {
            var env: [String: String] = [:]
            for key in ["TABLEEXTRA_HOME", "MYTABLEPLUS_HOME", "PGPASSWORD", "TABLEEXTRA_MCP_NO_KEYCHAIN"] {
                if let v = ProcessInfo.processInfo.environment[key] { env[key] = v }
            }
            access.databaseTools = .init(serverBinary: binary, connectionID: connection.id, environment: env)
        }
        return access
    }

    /// Previous turns, newest last, capped so long chats do not crowd out the schema.
    static func conversation(_ turns: [AIChatTurn], limit: Int = 8_000) -> String {
        var lines: [String] = []
        var used = 0
        for t in turns.reversed() {
            let text = t.text.count > 2_000 ? String(t.text.prefix(2_000)) + " …" : t.text
            let line = "\(t.isUser ? "Developer" : "You"): \(text)"
            if used + line.count > limit { break }
            lines.insert(line, at: 0)
            used += line.count
        }
        return "## Conversation so far\n" + lines.joined(separator: "\n\n")
    }

    static func accessPrompt(_ access: ClaudeCLI.Access, connection: ConnectionConfig, database: String) -> String {
        var s = ""
        if let repo = access.codeRepository {
            s += """

            The application code that uses this database is in your working directory (\(repo.path)). \
            When the question involves how data is used (models, migrations, Kysely/ORM types, queries, business rules), \
            look it up with Read, Grep and Glob, and cite file paths with line numbers. You cannot edit files.
            """
        }
        if access.databaseTools != nil {
            s += """

            You can query this database yourself, read-only, with the `tableextra` tools (connection "\(connection.id.uuidString)", \
            database "\(database)"): list_tables, describe_table, search_schema, run_query, explain_query. \
            Use run_query when the answer depends on the data; keep results small (LIMIT, aggregates). \
            Never try to modify data: propose writes in a ```sql block for the developer to review and run.
            """
        } else {
            s += "\nYou cannot query the database: reason from the schema and the attached context only."
        }
        if connection.isProductionLike {
            s += "\nThis is a \(connection.environment.displayName.uppercased()) database: be conservative, flag risky operations clearly."
        }
        return s
    }

    // MARK: Schema context

    @MainActor
    static func invalidateSchemaCache() { snapshotCache.removeAll() }

    @MainActor
    private static var snapshotCache: [String: (date: Date, tables: [TableDetails])] = [:]

    @MainActor
    static func snapshot(for context: WorkspaceContext) async throws -> [TableDetails] {
        let key = "\(context.connection.id)|\(context.currentDatabase)|\(context.currentSchema)"
        if let hit = snapshotCache[key], Date().timeIntervalSince(hit.date) < 300 { return hit.tables }
        let tables = try await context.introspector.snapshot(schema: context.currentSchema)
        snapshotCache[key] = (Date(), tables)
        return tables
    }

    /// Driver, version, schema summary (most relevant tables first, capped) and enums; sample rows only when enabled.
    @MainActor
    static func schemaContext(for context: WorkspaceContext, focus: String) async -> String {
        var input = AIContextInput(driver: context.connection.driver, serverVersion: context.serverInfo?.version,
                                   database: context.currentDatabase, schema: context.currentSchema,
                                   otherSchemas: context.schemas.filter { $0 != context.currentSchema },
                                   tables: [], focusText: focus, maxChars: AISettings.maxSchemaChars)
        do {
            input.tables = try await snapshot(for: context)
        } catch {
            input.schemaError = error.localizedDescription
        }
        if AISettings.includeSampleRows {
            for t in AIContextBuilder.mentionedTables(input.tables, in: focus).prefix(3) where t.object.kind.hasData {
                let sql = "SELECT * FROM \(context.dialect.qualified(schema: t.object.schema, name: t.object.name)) LIMIT 3"
                if let r = try? await context.client.query(sql, maxRows: 3) {
                    input.sampleRows[t.object.qualifiedName] = AIContextBuilder.renderRows(r)
                }
            }
        }
        return AIContextBuilder.build(input)
    }

    // MARK: Prompts


    static func systemPrompt(dialect: String) -> String {
        """
        You are a senior \(dialect) engineer helping a developer inside TableExtra, a database client. \
        You never change the database yourself: the developer reviews and runs every write you suggest. \
        Use only tables, columns and enum values from the schema context or from what your tools return; if something you need is missing, say so instead of inventing it. \
        Attached context (table definitions, rows, reports) comes from the screen the developer is looking at. \
        Write \(dialect) syntax only and qualify tables with their schema when it is not the current one. \
        Whenever your answer contains SQL, put all of it in exactly one fenced code block that starts with ```sql, and use no other code blocks. \
        Keep the prose short and practical.
        """
    }

    static func userPrompt(_ task: AITask, schemaContext: String, dialect: String) -> String {
        var s = "## Schema context\n\(schemaContext)\n\n## Task\n"
        switch task {
        case .generate(let question, let currentSQL):
            s += "Write \(dialect) SQL for this request:\n\(question)\n"
            if let sql = currentSQL?.trimmingCharacters(in: .whitespacesAndNewlines), !sql.isEmpty {
                s += "\nThe editor currently contains this SQL (use it only if the request refers to it):\n```sql\n\(capped(sql))\n```\n"
            }
            s += "\nAnswer with the ```sql block first, then at most three short sentences about assumptions."
        case .explain(let sql):
            s += """
            Explain what this SQL does, step by step, in plain language. Point out correctness or performance risks \
            (missing WHERE, NULL handling, implicit casts, unindexed filters, row explosion in joins). \
            Do not rewrite it unless there is a bug; if you do, put the corrected SQL in one ```sql block.

            ```sql
            \(capped(sql))
            ```
            """
        case .optimize(let sql, let plan):
            s += "Make this query faster without changing its result.\n```sql\n\(capped(sql))\n```\n"
            if let plan, !plan.isEmpty { s += "\nCurrent plan:\n```\n\(capped(plan))\n```\n" }
            s += """

            Put any CREATE INDEX statements (CONCURRENTLY on PostgreSQL) and the rewritten query together in one ```sql block, \
            then explain briefly why it is faster. If it is already optimal, say so and repeat the query.
            """
        case .custom(_, let prompt, let attachments, _):
            for a in attachments {
                s += "### \(a.title)\n```\n\(capped(a.content, 30_000))\n```\n\n"
            }
            s += prompt
        case .fix(let sql, let error):
            s += """
            This statement failed.
            ```sql
            \(capped(sql))
            ```
            Error:
            \(capped(error, 4_000))

            Return the corrected statement in one ```sql block, then one sentence explaining the cause.
            """
        }
        return s
    }

    private static func capped(_ s: String, _ limit: Int = 20_000) -> String {
        s.count > limit ? String(s.prefix(limit)) + "\n-- … truncated (\(s.count) characters)" : s
    }

    // MARK: Answer parsing

    private static let sqlLanguages: Set<String> = ["sql", "postgresql", "postgres", "psql", "pgsql", "plpgsql", "sqlite", "sqlite3"]

    /// The ```sql block of an answer; falls back to an untagged block, or to the whole text when it is bare SQL.
    static func extractSQL(from text: String) -> String? {
        let blocks = AIMarkdown.segments(text).compactMap { seg -> (lang: String, code: String)? in
            if case .code(let lang, let code) = seg { return (lang, code) }
            return nil
        }
        let pick = blocks.first { sqlLanguages.contains($0.lang.lowercased()) } ?? blocks.first { $0.lang.isEmpty }
        if let pick {
            let code = pick.code.trimmingCharacters(in: .whitespacesAndNewlines)
            return code.isEmpty ? nil : code
        }
        guard blocks.isEmpty else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let first = trimmed.split(whereSeparator: { !$0.isLetter }).first.map { $0.uppercased() } ?? ""
        let verbs: Set<String> = ["SELECT", "WITH", "INSERT", "UPDATE", "DELETE", "CREATE", "ALTER", "DROP", "EXPLAIN", "VALUES", "TRUNCATE"]
        return verbs.contains(first) ? trimmed : nil
    }
}

/// Markdown split into prose and fenced code blocks (for rendering and SQL extraction).
public enum AIMarkdown {
    public enum Segment: Equatable, Sendable {
        case text(String)
        case code(language: String, code: String)
    }

    public static func segments(_ text: String) -> [Segment] {
        var result: [Segment] = []
        var prose: [String] = []
        var code: [String]?
        var language = ""

        func flushProse() {
            let s = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { result.append(.text(s)) }
            prose = []
        }

        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if code != nil {
                if t.hasPrefix("```") && t.trimmingCharacters(in: CharacterSet(charactersIn: "`")).isEmpty {
                    result.append(.code(language: language, code: code!.joined(separator: "\n")))
                    code = nil
                } else if t.hasSuffix("```") && !t.hasPrefix("```") {
                    code!.append(String(line[..<line.range(of: "```", options: .backwards)!.lowerBound]))
                    result.append(.code(language: language, code: code!.joined(separator: "\n")))
                    code = nil
                } else {
                    code!.append(line)
                }
            } else if t.hasPrefix("```") {
                flushProse()
                var rest = String(t.dropFirst(3))
                if rest.count > 3 && rest.hasSuffix("```") {
                    // ```sql SELECT 1```
                    rest = String(rest.dropLast(3))
                    let parts = rest.split(separator: " ", maxSplits: 1).map(String.init)
                    let lang = parts.count == 2 && !parts[0].contains(where: { !$0.isLetter }) ? parts[0] : ""
                    result.append(.code(language: lang, code: lang.isEmpty ? rest : parts[1]))
                } else {
                    language = rest.split(separator: " ").first.map(String.init) ?? ""
                    code = []
                }
            } else {
                prose.append(line)
            }
        }
        if let code { result.append(.code(language: language, code: code.joined(separator: "\n"))) }
        flushProse()
        return result
    }
}

public struct AIContextInput: Sendable {
    public var driver: DriverKind
    public var serverVersion: String?
    public var database: String
    public var schema: String
    public var otherSchemas: [String] = []
    public var tables: [TableDetails]
    public var focusText: String = ""
    public var maxChars: Int = AISettings.defaultMaxSchemaChars
    /// Qualified table name → rendered rows (only when the user opted in).
    public var sampleRows: [String: String] = [:]
    public var schemaError: String?

    public init(driver: DriverKind, serverVersion: String?, database: String, schema: String, otherSchemas: [String] = [],
                tables: [TableDetails], focusText: String = "", maxChars: Int = AISettings.defaultMaxSchemaChars) {
        self.driver = driver
        self.serverVersion = serverVersion
        self.database = database
        self.schema = schema
        self.otherSchemas = otherSchemas
        self.tables = tables
        self.focusText = focusText
        self.maxChars = maxChars
    }
}

public enum AIContextBuilder {
    public static func build(_ input: AIContextInput) -> String {
        var out = "\(input.driver.displayName)"
        if let v = input.serverVersion, !v.isEmpty { out += " \(v)" }
        out += input.driver == .sqlite ? ", file database" : ", database \"\(input.database)\""
        out += ", current schema \"\(input.schema)\"."
        if !input.otherSchemas.isEmpty { out += " Other schemas: \(input.otherSchemas.joined(separator: ", "))." }
        out += "\n"
        if let e = input.schemaError { out += "(Schema could not be loaded: \(e))\n" }
        guard !input.tables.isEmpty else { return out + "(No tables in this schema.)" }

        let budget = max(500, input.maxChars)
        var enums: [String: [String]] = [:]
        for t in input.tables {
            for c in t.columns { if let e = c.enumValues, enums[c.udtName] == nil { enums[c.udtName] = e } }
        }
        if !enums.isEmpty {
            var block = "Enum types:\n"
            for name in enums.keys.sorted() {
                let line = "  \(name): \(enums[name]!.joined(separator: " | "))\n"
                if block.count + line.count > budget / 4 { block += "  …\n"; break }
                block += line
            }
            out += block
        }

        out += "Tables (name(column type [pk] [→ ref] [{enum}])):\n"
        var omitted: [String] = []
        for t in ordered(input.tables, focus: input.focusText) {
            let line = DDLWriter.compactSummary([t]) + "\n"
            if out.count + line.count > budget {
                omitted.append(t.object.qualifiedName)
            } else {
                out += line
            }
        }
        if !omitted.isEmpty {
            var names = ""
            for n in omitted {
                if names.count > 1_000 { names += ", …"; break }
                names += names.isEmpty ? n : ", \(n)"
            }
            out += "-- \(omitted.count) more tables not shown (context limit): \(names)\n"
        }
        if !input.sampleRows.isEmpty {
            out += "Sample rows:\n"
            for k in input.sampleRows.keys.sorted() { out += "  \(k):\n\(input.sampleRows[k]!)\n" }
        }
        return out.trimmingCharacters(in: .newlines)
    }

    /// Tables named in the text (exact, schema-qualified, or singular/plural form).
    public static func mentionedTables(_ tables: [TableDetails], in text: String) -> [TableDetails] {
        let lower = text.lowercased()
        let words = Set(lower.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") }).map(String.init))
        return tables.filter { t in
            let n = t.object.name.lowercased()
            if words.contains(n) || lower.contains(t.object.qualifiedName.lowercased()) { return true }
            if words.contains(n + "s") || words.contains(n + "es") { return true }
            if n.hasSuffix("s"), words.contains(String(n.dropLast())) { return true }
            if n.hasSuffix("ies"), words.contains(String(n.dropLast(3)) + "y") { return true }
            if n.contains("_") {
                // "order items" → order_items
                let spaced = n.replacingOccurrences(of: "_", with: " ")
                let stem = spaced.hasSuffix("s") ? String(spaced.dropLast()) : spaced
                if lower.contains(spaced) || (stem.count > 3 && lower.contains(stem)) { return true }
            }
            return false
        }
    }

    /// Mentioned tables first, then their foreign-key neighbours, then the rest in schema order.
    static func ordered(_ tables: [TableDetails], focus: String) -> [TableDetails] {
        let mentioned = mentionedTables(tables, in: focus)
        guard !mentioned.isEmpty else { return tables }
        let mentionedNames = Set(mentioned.map(\.object.name))
        var neighbourNames = Set<String>()
        for t in tables {
            let refs = Set(t.columns.compactMap { $0.foreignKey?.refTable } + t.constraints.compactMap { $0.foreignKey?.refTable })
            if mentionedNames.contains(t.object.name) {
                neighbourNames.formUnion(refs)
            } else if !refs.isDisjoint(with: mentionedNames) {
                neighbourNames.insert(t.object.name)
            }
        }
        neighbourNames.subtract(mentionedNames)
        let neighbours = tables.filter { neighbourNames.contains($0.object.name) }
        let rest = tables.filter { !mentionedNames.contains($0.object.name) && !neighbourNames.contains($0.object.name) }
        return mentioned + neighbours + rest
    }

    static func renderRows(_ r: QueryResult) -> String {
        r.rows.map { row in
            "    " + zip(r.columns, row).map { col, v in
                let s = v.map { $0.count > 40 ? String($0.prefix(40)) + "…" : $0 } ?? "NULL"
                return "\(col.name)=\(s.replacingOccurrences(of: "\n", with: " "))"
            }.joined(separator: ", ")
        }.joined(separator: "\n")
    }
}
