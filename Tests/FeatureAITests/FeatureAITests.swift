import MTPCore
import MTPUIKit
import XCTest
@testable import FeatureAI

/// Uses fake `claude` shell scripts: no real Claude call. "PG" tests need MTP_TEST_PG="host:port:user:password:db".
final class FeatureAITests: XCTestCase {
    var dir: URL!
    var suiteName: String!

    override func setUpWithError() throws {
        let base = ProcessInfo.processInfo.environment["TABLEEXTRA_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        dir = base.appendingPathComponent("ai-tests-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        suiteName = "mtp.ai.tests"
        AISettings.defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDownWithError() throws {
        AISettings.defaults.removePersistentDomain(forName: suiteName)
        AISettings.defaults = .standard
        try? FileManager.default.removeItem(at: dir)
        let plist = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(suiteName!).plist")
        try? FileManager.default.removeItem(at: plist)
    }

    // MARK: Fake claude

    static let okJSON = #"{"type":"result","subtype":"success","is_error":false,"duration_ms":12,"total_cost_usd":0.001,"result":"Here you go:\n```sql\nSELECT id, email FROM customers;\n```\nAssumes emails are unique.","modelUsage":{"claude-sonnet-test":{"inputTokens":1}}}"#

    func fakeClaude(_ name: String = "claude", body: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let script = """
        #!/bin/sh
        here="$(dirname "$0")"
        printf '%s\\n' "$@" > "$here/args.txt"
        env > "$here/env.txt"
        \(body)
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func okClaude() throws -> URL {
        try fakeClaude(body: "cat > \"$here/stdin.txt\"\ncat <<'JSON'\n\(Self.okJSON)\nJSON")
    }

    func read(_ name: String) -> String {
        (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? ""
    }

    // MARK: CLI

    func testPromptArguments() {
        let args = ClaudeCLI.promptArguments(model: "haiku", systemPrompt: "SYS")
        XCTAssertEqual(args, ["-p", "--output-format", "json", "--no-session-persistence", "--strict-mcp-config",
                              "--setting-sources", "user", "--disable-slash-commands", "--tools", "",
                              "--model", "haiku", "--system-prompt", "SYS"])
        XCTAssertFalse(ClaudeCLI.promptArguments(model: nil, systemPrompt: nil).contains("--model"))
    }

    func testPromptArgumentsWithRepositoryAndDatabaseTools() throws {
        let repo = URL(fileURLWithPath: "/tmp/app-repo")
        let id = UUID()
        let access = ClaudeCLI.Access(codeRepository: repo,
                                      databaseTools: .init(serverBinary: URL(fileURLWithPath: "/x/tableextra-mcp"), connectionID: id))
        let args = ClaudeCLI.promptArguments(model: nil, systemPrompt: nil, access: access)
        let tools = try XCTUnwrap(args.firstIndex(of: "--tools"))
        XCTAssertEqual(args[tools + 1], "Read,Grep,Glob")
        XCTAssertEqual(args[try XCTUnwrap(args.firstIndex(of: "--add-dir")) + 1], "/tmp/app-repo")
        let allowed = args[try XCTUnwrap(args.firstIndex(of: "--allowedTools")) + 1]
        XCTAssertTrue(allowed.contains("mcp__tableextra__run_query"))
        XCTAssertFalse(allowed.contains("execute_statement"), "the assistant never gets the write tool")
        XCTAssertFalse(allowed.contains("Edit") || allowed.contains("Bash") || allowed.contains("Write"))
        let config = args[try XCTUnwrap(args.firstIndex(of: "--mcp-config")) + 1]
        XCTAssertTrue(config.contains(id.uuidString) && config.contains("TABLEEXTRA_MCP_ONLY"))
        XCTAssertEqual(args[try XCTUnwrap(args.firstIndex(of: "--setting-sources")) + 1], "user")
    }

    func testAskWithFakeClaude() async throws {
        let cli = ClaudeCLI(executableURL: try okClaude())
        setenv("CLAUDECODE", "1", 1)
        defer { unsetenv("CLAUDECODE") }
        let r = try await cli.ask("list customers\nplease", model: "opus", systemPrompt: "be brief")
        XCTAssertTrue(r.text.contains("SELECT id, email FROM customers;"))
        XCTAssertEqual(r.model, "claude-sonnet-test")
        XCTAssertEqual(r.durationMS, 12)
        XCTAssertEqual(read("stdin.txt"), "list customers\nplease")
        let args = read("args.txt").components(separatedBy: "\n")
        XCTAssertEqual(Array(args.prefix(14)), ["-p", "--output-format", "json", "--no-session-persistence", "--strict-mcp-config",
                                                "--setting-sources", "user", "--disable-slash-commands", "--tools", "",
                                                "--model", "opus", "--system-prompt", "be brief"])
        let env = read("env.txt")
        XCTAssertFalse(env.contains("CLAUDECODE="), "nested-session marker must not reach claude")
        XCTAssertTrue(env.contains("PATH="))
    }

    func testNotLoggedIn() async throws {
        let json = #"{"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login","duration_ms":31}"#
        let cli = ClaudeCLI(executableURL: try fakeClaude(body: "cat >/dev/null\necho '\(json)'\nexit 1"))
        do {
            _ = try await cli.ask("hi")
            XCTFail("expected an error")
        } catch let e as ClaudeCLIError {
            guard case .notLoggedIn = e else { return XCTFail("got \(e)") }
            XCTAssertTrue(e.errorDescription!.contains("/login"))
        }
    }

    func testFailureWithoutJSON() async throws {
        let cli = ClaudeCLI(executableURL: try fakeClaude(body: "cat >/dev/null\necho 'error: unknown option --tools' >&2\nexit 2"))
        do {
            _ = try await cli.ask("hi")
            XCTFail("expected an error")
        } catch let e as ClaudeCLIError {
            XCTAssertEqual(e, .failed("error: unknown option --tools"))
        }
    }

    func testMissingBinary() async throws {
        let cli = ClaudeCLI(executableURL: dir.appendingPathComponent("nope"))
        do {
            _ = try await cli.ask("hi")
            XCTFail("expected an error")
        } catch let e as ClaudeCLIError {
            XCTAssertEqual(e, .notFound)
        }
        AISettings.claudePath = dir.appendingPathComponent("nope").path
        XCTAssertThrowsError(try ClaudeCLI.resolved()) { XCTAssertEqual($0 as? ClaudeCLIError, .notFound) }
    }

    func testTimeoutTerminates() async throws {
        let cli = ClaudeCLI(executableURL: try fakeClaude(body: "cat >/dev/null\nexec sleep 30"))
        let start = Date()
        do {
            _ = try await cli.ask("hi", timeout: 1)
            XCTFail("expected a timeout")
        } catch let e as ClaudeCLIError {
            XCTAssertEqual(e, .timedOut(1))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 6)
    }

    func testCancellationTerminates() async throws {
        let cli = ClaudeCLI(executableURL: try fakeClaude(body: "cat >/dev/null\nexec sleep 30"))
        let start = Date()
        let task = Task { try await cli.ask("hi", timeout: 60) }
        try await Task.sleep(nanoseconds: 400_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch let e as ClaudeCLIError {
            XCTAssertEqual(e, .cancelled)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 6)
    }

    func testParseArrayAndNoise() throws {
        let out = ProcessOutput(status: 0, stdout: "[{\"type\":\"system\"},{\"type\":\"result\",\"is_error\":false,\"result\":\"hi\"}]", stderr: "")
        XCTAssertEqual(try ClaudeCLI.parse(out).text, "hi")
        let lines = ProcessOutput(status: 0, stdout: "warning: something\n{\"type\":\"result\",\"result\":\"ok\"}\n", stderr: "")
        XCTAssertEqual(try ClaudeCLI.parse(lines).text, "ok")
        XCTAssertThrowsError(try ClaudeCLI.parse(ProcessOutput(status: 0, stdout: "plain text", stderr: "")))
    }

    func testLocateOverrideAndCandidates() throws {
        let fake = try okClaude()
        XCTAssertEqual(ClaudeCLI.locate(override: fake.path, useLoginShell: false)?.path, fake.path)
        XCTAssertNil(ClaudeCLI.locate(override: "/nonexistent/claude", useLoginShell: false))
        XCTAssertEqual(ClaudeCLI.locate(override: nil, candidates: ["/nonexistent/claude", fake.path], useLoginShell: false)?.path, fake.path)
        XCTAssertNil(ClaudeCLI.locate(override: nil, candidates: ["/nonexistent/claude"], useLoginShell: false))
        AISettings.claudePath = fake.path
        XCTAssertEqual(try ClaudeCLI.resolved().executableURL.path, fake.path)
    }

    /// Opt-in (uses the real subscription): MTP_REAL_CLAUDE=1.
    func testRealClaudeOptIn() async throws {
        guard ProcessInfo.processInfo.environment["MTP_REAL_CLAUDE"] == "1" else { throw XCTSkip("MTP_REAL_CLAUDE not set") }
        let cli = try ClaudeCLI.resolved()
        let r = try await cli.ask("Reply with exactly: OK", model: "haiku", systemPrompt: "You answer tersely.", timeout: 90)
        XCTAssertEqual(r.text.trimmingCharacters(in: .whitespacesAndNewlines), "OK")
        print("real claude:", cli.executableURL.path, r.model ?? "-", r.durationMS ?? -1)
    }

    // MARK: Parsing

    func testExtractSQL() {
        XCTAssertEqual(AIService.extractSQL(from: "Sure:\n```sql\nSELECT 1;\n```\nDone."), "SELECT 1;")
        XCTAssertEqual(AIService.extractSQL(from: "```SQL\nselect 2\n```"), "select 2")
        XCTAssertEqual(AIService.extractSQL(from: "```postgresql\nSELECT 3\n```"), "SELECT 3")
        XCTAssertEqual(AIService.extractSQL(from: "```text\nnote\n```\n```sql\nSELECT 4\n```"), "SELECT 4")
        XCTAssertEqual(AIService.extractSQL(from: "```\nSELECT 5\n```"), "SELECT 5")
        XCTAssertEqual(AIService.extractSQL(from: "Answer:\n  ```sql\n  SELECT 6\n  FROM t\n  ```"), "SELECT 6\n  FROM t")
        XCTAssertEqual(AIService.extractSQL(from: "```sql\nSELECT 7 -- unterminated"), "SELECT 7 -- unterminated")
        XCTAssertEqual(AIService.extractSQL(from: "```sql SELECT 8```"), "SELECT 8")
        XCTAssertEqual(AIService.extractSQL(from: "SELECT 9 FROM t"), "SELECT 9 FROM t")
        XCTAssertNil(AIService.extractSQL(from: "This query scans orders by date."))
        XCTAssertNil(AIService.extractSQL(from: "```json\n{}\n```"))
    }

    func testSegments() {
        let s = AIMarkdown.segments("Intro **bold**\n```sql\nSELECT 1;\n```\nOutro")
        XCTAssertEqual(s, [.text("Intro **bold**"), .code(language: "sql", code: "SELECT 1;"), .text("Outro")])
    }

    // MARK: Context

    func table(_ name: String, _ cols: [ColumnDef]) -> TableDetails {
        TableDetails(object: DBObject(schema: "public", name: name, kind: .table), columns: cols, indexes: [], constraints: [], triggers: [])
    }

    func col(_ name: String, _ type: String = "int8", pk: Bool = false, ref: String? = nil, enumValues: [String]? = nil) -> ColumnDef {
        var c = ColumnDef(name: name, dataType: type, udtName: type, isNullable: !pk, isPrimaryKey: pk, ordinal: 0)
        c.enumValues = enumValues
        if let ref { c.foreignKey = ForeignKeyRef(constraintName: "fk_\(name)", columns: [name], refSchema: "public", refTable: ref, refColumns: ["id"]) }
        return c
    }

    func sampleTables() -> [TableDetails] {
        var tables = (0..<200).map { i in table("filler_\(i)", (0..<8).map { col("column_number_\($0)", "text") }) }
        tables.append(table("customers", [col("id", pk: true), col("email", "text")]))
        tables.append(table("orders", [col("id", pk: true), col("customer_id", ref: "customers"),
                                       col("status", "order_status", enumValues: ["pending", "paid", "shipped"])]))
        tables.append(table("order_items", [col("id", pk: true), col("order_id", ref: "orders")]))
        return tables
    }

    func testContextPrioritisesMentionedTablesAndCaps() {
        let input = AIContextInput(driver: .postgres, serverVersion: "14.12", database: "shop", schema: "public",
                                   otherSchemas: ["analytics"], tables: sampleTables(),
                                   focusText: "total paid per customer from the orders", maxChars: 3_000)
        let text = AIContextBuilder.build(input)
        XCTAssertLessThanOrEqual(text.count, 3_000 + 1_200)
        XCTAssertTrue(text.hasPrefix("PostgreSQL 14.12, database \"shop\", current schema \"public\". Other schemas: analytics."))
        XCTAssertTrue(text.contains("order_status: pending | paid | shipped"))
        XCTAssertTrue(text.contains("public.orders(id int8 pk, customer_id int8 → customers.id, status order_status {pending|paid|shipped})"))
        XCTAssertTrue(text.contains("public.customers(id int8 pk, email text)"))
        XCTAssertTrue(text.contains("public.order_items("), "FK neighbour of a mentioned table comes early")
        let ordersAt = text.range(of: "public.orders(")!.lowerBound
        if let filler = text.range(of: "public.filler_0(") { XCTAssertLessThan(ordersAt, filler.lowerBound) }
        XCTAssertTrue(text.contains("more tables not shown"))
        XCTAssertFalse(text.contains("Sample rows"))
    }

    func testContextSmallSchemaIsComplete() {
        let tables = Array(sampleTables().suffix(3))
        let text = AIContextBuilder.build(AIContextInput(driver: .sqlite, serverVersion: "3.45", database: "", schema: "main", tables: tables))
        XCTAssertTrue(text.hasPrefix("SQLite 3.45, file database"))
        XCTAssertFalse(text.contains("not shown"))
        XCTAssertEqual(AIContextBuilder.mentionedTables(tables, in: "each customer and their email").map(\.object.name), ["customers"])
        XCTAssertEqual(AIContextBuilder.mentionedTables(tables, in: "order items per order").map(\.object.name), ["orders", "order_items"])
    }

    func testPromptsAskForSingleSQLBlock() {
        XCTAssertTrue(AIService.systemPrompt(dialect: "PostgreSQL").contains("exactly one fenced code block that starts with ```sql"))
        let p = AIService.userPrompt(.fix(sql: "SELEC 1", error: "syntax error at or near \"SELEC\""), schemaContext: "CTX", dialect: "PostgreSQL")
        XCTAssertTrue(p.hasPrefix("## Schema context\nCTX\n\n## Task\n"))
        XCTAssertTrue(p.contains("SELEC 1") && p.contains("syntax error"))
        let g = AIService.userPrompt(.generate(question: "count orders", currentSQL: "  "), schemaContext: "", dialect: "SQLite")
        XCTAssertFalse(g.contains("editor currently contains"))
        let o = AIService.userPrompt(.optimize(sql: "SELECT 1", plan: "Seq Scan on t"), schemaContext: "", dialect: "PostgreSQL")
        XCTAssertTrue(o.contains("Seq Scan on t"))
    }

    // MARK: MCP installer

    func testMCPCommands() {
        let path = "/Applications/My TablePlus.app/Contents/MacOS/tableextra-mcp"
        XCTAssertEqual(MCPInstaller.addArguments(binaryPath: path), ["mcp", "add", "--scope", "user", "tableextra", "--", path])
        XCTAssertEqual(MCPInstaller.removeArguments(), ["mcp", "remove", "--scope", "user", "tableextra"])
        XCTAssertEqual(MCPInstaller.getArguments(), ["mcp", "get", "tableextra"])
        XCTAssertEqual(MCPInstaller.displayCommand(MCPInstaller.addArguments(binaryPath: path)),
                       "claude mcp add --scope user tableextra -- '/Applications/My TablePlus.app/Contents/MacOS/tableextra-mcp'")
        XCTAssertEqual(MCPInstaller.shellQuote("it's"), "'it'\\''s'")
        let json = MCPInstaller.jsonSnippet(binaryPath: "/x/tableextra-mcp")
        let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: [String: [String: Any]]]
        XCTAssertEqual(obj?["mcpServers"]?["tableextra"]?["command"] as? String, "/x/tableextra-mcp")
    }

    func testMCPCommandRunsThroughCLI() async throws {
        // Checks the exact argv handed to claude, without touching the real Claude Code config.
        let cli = ClaudeCLI(executableURL: try fakeClaude(body: "echo added"))
        let out = try await cli.run(MCPInstaller.addArguments(binaryPath: "/p/with space/tableextra-mcp"))
        XCTAssertEqual(out.status, 0)
        XCTAssertEqual(out.stdout, "added\n")
        XCTAssertEqual(read("args.txt"), "mcp\nadd\n--scope\nuser\ntableextra\n--\n/p/with space/tableextra-mcp\n")
    }

    func testBinaryURLFallsBackToSibling() {
        let url = MCPInstaller.binaryURL()
        XCTAssertEqual(url.lastPathComponent, "tableextra-mcp")
    }

    func testAuditLogNewestFirst() throws {
        let log = dir.appendingPathComponent("mcp-audit.log")
        let old = #"{"ts":"2026-10-23T08:00:00.000Z","tool":"list_connections","status":"ok","outcome":"3 connections","duration_ms":1}"#
        let mid = #"{"ts":"2026-10-23T09:00:00.000Z","tool":"run_query","connection":"dev","sql":"select 1","status":"ok","outcome":"1 row","duration_ms":4}"#
        let new = #"{"ts":"2026-10-23T10:00:00.000Z","tool":"execute_statement","connection":"prod","sql":"delete from t","status":"refused","outcome":"production","duration_ms":0,"client":"claude-code"}"#
        try (old + "\n").write(to: log.appendingPathExtension("1"), atomically: true, encoding: .utf8)
        try (mid + "\nnot json\n" + new + "\n").write(to: log, atomically: true, encoding: .utf8)
        let entries = MCPInstaller.readAuditLog(url: log)
        XCTAssertEqual(entries.map(\.tool), ["execute_statement", "run_query", "list_connections"])
        XCTAssertEqual(entries[0].status, "refused")
        XCTAssertNotNil(entries[0].date)
        XCTAssertEqual(Set(entries.map(\.id)).count, 3)
        XCTAssertEqual(MCPInstaller.readAuditLog(url: log, limit: 1).count, 1)
    }

    // MARK: PostgreSQL end to end (fake claude)

    @MainActor
    func makePGContext() async throws -> StandaloneWorkspaceContext {
        guard let spec = ProcessInfo.processInfo.environment["MTP_TEST_PG"] else { throw XCTSkip("MTP_TEST_PG not set") }
        let p = spec.split(separator: ":").map(String.init)
        let config = ConnectionConfig(name: "ai-test", driver: .postgres, host: p[0], port: Int(p[1]), user: p[2], database: p[4],
                                      sslMode: .disable, environment: .development)
        let ctx = StandaloneWorkspaceContext(connection: config, secrets: ConnectionSecrets(password: p[3]))
        try await ctx.prepare()
        return ctx
    }

    @MainActor
    func testPGGenerateSQLWithFakeClaude() async throws {
        let ctx = try await makePGContext()
        defer { ctx.client.close() }
        AIService.invalidateSchemaCache()
        AISettings.claudePath = try okClaude().path
        AISettings.defaultModel = "haiku"
        let answer = try await AIService.generateSQL(question: "emails of customers with paid orders", context: ctx, currentSQL: "SELECT 1")
        XCTAssertEqual(answer.sql, "SELECT id, email FROM customers;")
        let prompt = read("stdin.txt")
        XCTAssertTrue(prompt.contains("PostgreSQL 14"), prompt.prefix(200).description)
        XCTAssertTrue(prompt.contains("database \"shop\""))
        XCTAssertTrue(prompt.contains("public.orders("))
        XCTAssertTrue(prompt.contains("public.customers("))
        XCTAssertTrue(prompt.contains("order_status:"), "enum values are listed")
        XCTAssertTrue(prompt.contains("Other schemas: analytics"))
        XCTAssertTrue(prompt.contains("emails of customers with paid orders"))
        XCTAssertTrue(prompt.contains("```sql\nSELECT 1\n```"))
        XCTAssertFalse(prompt.contains("Sample rows"), "sample rows are off by default")
        let args = read("args.txt")
        XCTAssertTrue(args.contains("--model\nhaiku\n"))
        XCTAssertTrue(args.contains("--system-prompt\nYou are a senior PostgreSQL engineer"))

        let fixed = try await AIService.fix(sql: "SELEC id FROM customers", error: "syntax error at or near \"SELEC\"", context: ctx)
        XCTAssertEqual(fixed, "SELECT id, email FROM customers;")
        XCTAssertTrue(read("stdin.txt").contains("syntax error at or near"))
        XCTAssertTrue(ctx.openedQueries.isEmpty, "the service never executes or opens anything by itself")
    }

    @MainActor
    func testPGSampleRowsWhenEnabled() async throws {
        let ctx = try await makePGContext()
        defer { ctx.client.close() }
        AIService.invalidateSchemaCache()
        AISettings.claudePath = try okClaude().path
        AISettings.includeSampleRows = true
        _ = try await AIService.explain(sql: "SELECT * FROM customers", context: ctx)
        let prompt = read("stdin.txt")
        XCTAssertTrue(prompt.contains("Sample rows:\n  public.customers:"))
        XCTAssertFalse(prompt.contains("  public.orders:"), "only tables mentioned in the request get samples")
    }

    @MainActor
    func testPGNotFoundSurfaces() async throws {
        let ctx = try await makePGContext()
        defer { ctx.client.close() }
        AISettings.claudePath = "/nonexistent/claude"
        do {
            _ = try await AIService.optimize(sql: "SELECT 1", context: ctx, plan: nil)
            XCTFail("expected notFound")
        } catch let e as ClaudeCLIError {
            XCTAssertEqual(e, .notFound)
        }
    }
}
