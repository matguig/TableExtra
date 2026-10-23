import MTPCore
import XCTest
@testable import tableextra_mcp

/// In-process tests of the JSON-RPC handler. Policy checks need no database; the ones tagged
/// "PG" run against MTP_TEST_PG="host:port:user:password:db" and leave no trace (temp tables only).
final class MCPServerTests: XCTestCase {
    var dir: URL!
    var connections: [ConnectionConfig] = []
    var password: String?
    var server: MCPServer!

    override func setUpWithError() throws {
        let base = ProcessInfo.processInfo.environment["TABLEEXTRA_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        dir = base.appendingPathComponent("mcp-tests-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var host = "127.0.0.1", port = 5432, user = "postgres", db = "postgres"
        if let spec = ProcessInfo.processInfo.environment["MTP_TEST_PG"] {
            let p = spec.split(separator: ":").map(String.init)
            host = p[0]; port = Int(p[1]) ?? 5432; user = p[2]; password = p[3]; db = p[4]
        }
        func pg(_ name: String, _ env: ConnectionEnvironment, _ access: MCPAccess, safety: SafetyLevel = .silent) -> ConnectionConfig {
            ConnectionConfig(name: name, driver: .postgres, host: host, port: port, user: user, database: db, sslMode: .disable,
                             environment: env, safety: safety, mcpAccess: access)
        }
        let sqlitePath = dir.appendingPathComponent("t.sqlite").path
        let setup = try SQLiteDriver(path: sqlitePath)
        _ = try setup.execute("CREATE TABLE notes (id INTEGER PRIMARY KEY, title TEXT NOT NULL); INSERT INTO notes (title) VALUES ('a'), ('b');",
                              params: [], maxRows: nil)
        setup.close()
        connections = [
            pg("dev", .development, .readWrite),
            pg("prod", .production, .readWrite, safety: .confirmWrites),
            pg("staging-ro", .staging, .readOnly),
            pg("hidden", .development, .none),
            pg("dev-readonly-agent", .development, .readOnly),
            ConnectionConfig(name: "notes", driver: .sqlite, filePath: sqlitePath, environment: .local, mcpAccess: .readWrite),
        ]
        let snapshot = connections
        let pw = password
        let env = MCPEnvironment(connections: { snapshot }, secrets: { _ in ConnectionSecrets(password: pw) },
                                 audit: AuditLog(url: dir.appendingPathComponent("mcp-audit.log")),
                                 history: HistoryStore(url: dir.appendingPathComponent("history.sqlite")))
        server = MCPServer(environment: env)
    }

    override func tearDownWithError() throws {
        server.shutdown()
        try? FileManager.default.removeItem(at: dir)
    }

    func requirePG() throws {
        if password == nil { throw XCTSkip("MTP_TEST_PG not set") }
    }

    // MARK: Helpers

    @discardableResult
    func send(_ json: String) async throws -> JSONValue {
        let out = await server.handle(line: json)
        let line = try XCTUnwrap(out, "expected a response to \(json)")
        XCTAssertFalse(line.contains("\n"), "responses must be single-line")
        return try JSONValue.parse(line)
    }

    func call(_ tool: String, _ args: JSONValue) async throws -> (text: String, isError: Bool) {
        let request: JSONValue = ["jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": ["name": .string(tool), "arguments": args]]
        let r = try await send(request.serialized())
        XCTAssertNil(r["error"], "unexpected protocol error \(r.serialized())")
        let text = r["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        return (text, r["result"]?["isError"]?.boolValue ?? false)
    }

    func auditEntries() throws -> [AuditEntry] {
        let data = try Data(contentsOf: dir.appendingPathComponent("mcp-audit.log"))
        return try String(decoding: data, as: UTF8.self).split(separator: "\n").map {
            try JSONDecoder().decode(AuditEntry.self, from: Data($0.utf8))
        }
    }

    // MARK: Protocol

    func testInitializeEchoesSupportedVersion() async throws {
        let r = try await send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"claude-code","version":"2.1"}}}"#)
        XCTAssertEqual(r["id"], .int(1))
        XCTAssertEqual(r["result"]?["protocolVersion"]?.stringValue, "2025-06-18")
        XCTAssertEqual(r["result"]?["serverInfo"]?["name"]?.stringValue, "tableextra")
        XCTAssertNotNil(r["result"]?["serverInfo"]?["version"]?.stringValue)
        XCTAssertNotNil(r["result"]?["capabilities"]?["tools"]?.objectValue)
        XCTAssertEqual(server.tools.clientName, "claude-code 2.1")
    }

    func testInitializeUnknownVersionGetsNewest() async throws {
        let r = try await send(#"{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#)
        XCTAssertEqual(r["id"], .string("init"))
        XCTAssertEqual(r["result"]?["protocolVersion"]?.stringValue, MCPServer.supportedProtocolVersions.first)
    }

    func testNotificationsAndPing() async throws {
        let none = await server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(none)
        let r = try await send(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)
        XCTAssertEqual(r["result"], .object([:]))
    }

    func testErrors() async throws {
        let unknown = try await send(#"{"jsonrpc":"2.0","id":3,"method":"resources/list"}"#)
        XCTAssertEqual(unknown["error"]?["code"], .int(-32601))
        let badTool = try await send(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"drop_everything","arguments":{}}}"#)
        XCTAssertEqual(badTool["error"]?["code"], .int(-32602))
        let noName = try await send(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{}}"#)
        XCTAssertEqual(noName["error"]?["code"], .int(-32602))
        let badArgs = try await send(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"run_query","arguments":[1]}}"#)
        XCTAssertEqual(badArgs["error"]?["code"], .int(-32602))
        let parse = try await send("{not json")
        XCTAssertEqual(parse["error"]?["code"], .int(-32700))
        XCTAssertEqual(parse["id"], .null)
        // Missing tool arguments are tool errors (the agent can fix them), not protocol errors.
        let missing = try await call("run_query", ["connection": "dev"])
        XCTAssertTrue(missing.isError)
        XCTAssertTrue(missing.text.contains("sql"))
    }

    func testToolsList() async throws {
        let r = try await send(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        let tools = try XCTUnwrap(r["result"]?["tools"]?.arrayValue)
        XCTAssertEqual(Set(tools.compactMap { $0["name"]?.stringValue }), Set(MCPTools.names))
        for t in tools {
            XCTAssertEqual(t["inputSchema"]?["type"]?.stringValue, "object", t.serialized())
            XCTAssertFalse(t["description"]?.stringValue?.isEmpty ?? true)
        }
        let exec = tools.first { $0["name"]?.stringValue == "execute_statement" }
        XCTAssertEqual(exec?["annotations"]?["readOnlyHint"], .bool(false))
        let run = tools.first { $0["name"]?.stringValue == "run_query" }
        XCTAssertEqual(run?["inputSchema"]?["required"], ["connection", "sql"])
    }

    // MARK: Policy (no database needed: refusals happen before connecting)

    func testListConnectionsHidesNone() async throws {
        let r = try await call("list_connections", [:])
        XCTAssertFalse(r.isError)
        XCTAssertTrue(r.text.contains("dev"))
        XCTAssertTrue(r.text.contains("read-only (production)"))
        XCTAssertFalse(r.text.contains("hidden"))
        let hidden = try await call("list_tables", ["connection": "hidden"])
        XCTAssertTrue(hidden.isError)
        XCTAssertTrue(hidden.text.contains("No connection"))
    }

    func testRunQueryRefusesDelete() async throws {
        let r = try await call("run_query", ["connection": "dev", "sql": "DELETE FROM customers WHERE id = 1"])
        XCTAssertTrue(r.isError)
        XCTAssertTrue(r.text.hasPrefix("Refused"), r.text)
        for sql in ["select 1; delete from orders", "with x as (delete from orders returning *) select * from x", "update a set b = 1",
                    "set transaction read write; select 1", "commit; select 1", "copy (select 1) to program 'id'",
                    "select pg_terminate_backend(42)", "explain analyze delete from orders", "select * into t2 from orders"] {
            let refused = try await call("run_query", ["connection": "dev", "sql": .string(sql)])
            XCTAssertTrue(refused.isError && refused.text.hasPrefix("Refused"), "\(sql) → \(refused.text)")
        }
        let audit = try auditEntries()
        XCTAssertEqual(audit.first?.tool, "run_query")
        XCTAssertEqual(audit.first?.status, "refused")
        XCTAssertEqual(audit.first?.connection, "dev")
        XCTAssertEqual(audit.first?.sql, "DELETE FROM customers WHERE id = 1")
    }

    func testExecuteStatementRefusedOnProduction() async throws {
        let prod = try await call("execute_statement", ["connection": "prod", "sql": "UPDATE products SET stock = 0 WHERE id = 1"])
        XCTAssertTrue(prod.isError)
        XCTAssertTrue(prod.text.contains("production"), prod.text)
        let staging = try await call("execute_statement", ["connection": "staging-ro", "sql": "INSERT INTO t VALUES (1)"])
        XCTAssertTrue(staging.isError)
        let readOnlyAgent = try await call("execute_statement", ["connection": "dev-readonly-agent", "sql": "INSERT INTO t VALUES (1)"])
        XCTAssertTrue(readOnlyAgent.isError)
        XCTAssertTrue(readOnlyAgent.text.contains("MCP access"), readOnlyAgent.text)
        let tx = try await call("execute_statement", ["connection": "dev", "sql": "BEGIN; DELETE FROM t WHERE id = 1; COMMIT"])
        XCTAssertTrue(tx.isError)
        let unbounded = try await call("execute_statement", ["connection": "dev", "sql": "DELETE FROM orders"])
        XCTAssertTrue(unbounded.isError && unbounded.text.contains("confirm_destructive"), unbounded.text)
        XCTAssertEqual(try auditEntries().map(\.status), Array(repeating: "refused", count: 5))
    }

    func testWritePolicy() {
        var c = ConnectionConfig(name: "x", environment: .development, safety: .silent, mcpAccess: .readWrite)
        XCTAssertNil(WritePolicy.refusal(for: c))
        c.safety = .readOnly
        XCTAssertNotNil(WritePolicy.refusal(for: c))
        c.safety = .protectedWrites
        XCTAssertNotNil(WritePolicy.refusal(for: c))
        c.safety = .confirmWrites
        XCTAssertNil(WritePolicy.refusal(for: c))
        c.environment = .staging
        XCTAssertNotNil(WritePolicy.refusal(for: c))
        // Decoding a file without mcpAccess must never grant writes.
        let legacy = try! JSONDecoder().decode(ConnectionConfig.self, from: Data(#"{"id":"\#(UUID().uuidString)","name":"old"}"#.utf8))
        XCTAssertNotNil(WritePolicy.refusal(for: legacy))
    }

    func testSQLGuard() {
        XCTAssertNil(SQLGuard.readOnlyViolation("select 1; show search_path; values (1); with a as (select 1) select * from a", driver: .postgres))
        XCTAssertNil(SQLGuard.readOnlyViolation("explain select * from orders", driver: .postgres))
        XCTAssertNil(SQLGuard.readOnlyViolation("select 'pg_terminate_backend(1)' as s", driver: .postgres))
        XCTAssertNotNil(SQLGuard.readOnlyViolation("", driver: .postgres))
        XCTAssertNotNil(SQLGuard.readOnlyViolation("select \"dblink_exec\"('x', 'y')", driver: .postgres))
        XCTAssertNotNil(SQLGuard.readOnlyViolation("attach database 'x' as y", driver: .sqlite))
        XCTAssertNotNil(SQLGuard.readOnlyViolation("pragma journal_mode = delete", driver: .sqlite))
        XCTAssertNil(SQLGuard.readOnlyViolation("pragma table_info(notes)", driver: .sqlite))
        XCTAssertNil(SQLGuard.explainViolation("delete from orders where id = 1;", driver: .postgres))
        XCTAssertNotNil(SQLGuard.explainViolation("select 1; delete from orders", driver: .postgres))
        XCTAssertNotNil(SQLGuard.explainViolation("explain analyze select 1", driver: .postgres))
        XCTAssertEqual(SQLGuard.stripTrailingSemicolon(" select 1 ;; "), "select 1")
        XCTAssertEqual(MCPTools.likePattern("customer"), "%customer%")
        XCTAssertEqual(MCPTools.likePattern("created_*"), "created_%")
        XCTAssertEqual(MCPTools.splitQualified("analytics.events").0, "analytics")
        XCTAssertEqual(MCPTools.splitQualified("\"My Table\"").1, "My Table")
    }

    func testTextTable() {
        let t = TextTable.render(headers: ["id", "name"], rows: [["1", "a\nb"], ["22", nil]])
        XCTAssertEqual(t, "id | name\n---+-----\n1  | a\\nb\n22 | NULL")
        XCTAssertEqual(TextTable.csv(headers: ["a", "b"], rows: [["x,y", nil]]), "a,b\n\"x,y\",")
    }

    // MARK: SQLite (local temp file)

    func testSQLiteReadAndWrite() async throws {
        let rows = try await call("run_query", ["connection": "notes", "sql": "SELECT id, title FROM notes ORDER BY id"])
        XCTAssertFalse(rows.isError, rows.text)
        XCTAssertTrue(rows.text.contains("2 rows"), rows.text)
        let write = try await call("execute_statement", ["connection": "notes", "sql": "INSERT INTO notes (title) VALUES ('c'); UPDATE notes SET title = 'B' WHERE id = 2"])
        XCTAssertFalse(write.isError, write.text)
        XCTAssertTrue(write.text.contains("Total rows affected: 2"), write.text)
        let plan = try await call("explain_query", ["connection": "notes", "sql": "SELECT * FROM notes WHERE id = 1"])
        XCTAssertTrue(plan.text.contains("SEARCH"), plan.text)
        let describe = try await call("describe_table", ["connection": "notes", "table": "NOTES"])
        XCTAssertTrue(describe.text.contains("main.notes"), describe.text)
        // Second line of defence: the read handle itself cannot write.
        let config = try XCTUnwrap(connections.first { $0.name == "notes" })
        let reader = server.tools.pool.client(for: config, readOnly: true)
        do {
            _ = try await reader.query("DELETE FROM notes")
            XCTFail("read-only SQLite handle accepted a write")
        } catch let e as DatabaseError {
            XCTAssertTrue(e.message.lowercased().contains("readonly"), e.message)
        }
    }

    // MARK: PostgreSQL

    func testPGReadTools() async throws {
        try requirePG()
        let q = try await call("run_query", ["connection": "dev", "sql": "SELECT id, email FROM customers ORDER BY id", "max_rows": 5])
        XCTAssertFalse(q.isError, q.text)
        XCTAssertTrue(q.text.contains("5 rows") && q.text.contains("truncated"), q.text)
        let exact = try await call("run_query", ["connection": "dev", "sql": "SELECT g FROM generate_series(1, 5) g", "max_rows": 5])
        XCTAssertFalse(exact.text.contains("truncated"), exact.text)
        let csv = try await call("run_query", ["connection": "dev", "sql": "SELECT 1 AS a, 'x,y' AS b", "format": "csv"])
        XCTAssertTrue(csv.text.hasPrefix("a,b\n1,\"x,y\""), csv.text)
        // READ ONLY transaction blocks side effects the classifier lets through.
        let seq = try await call("run_query", ["connection": "dev", "sql": "SELECT nextval('orders_id_seq')"])
        XCTAssertTrue(seq.isError && seq.text.contains("read-only transaction"), seq.text)
        let d = try await call("describe_table", ["connection": "dev", "table": "orders"])
        XCTAssertTrue(d.text.contains("enum: pending, paid, shipped, cancelled"), d.text)
        XCTAssertTrue(d.text.contains("FK → public.customers(id)"), d.text)
        XCTAssertTrue(d.text.contains("order_items(order_id)"), d.text)
        let t = try await call("list_tables", ["connection": "dev"])
        XCTAssertTrue(t.text.contains("orders") && t.text.contains("materialized view"), t.text)
        let s = try await call("search_schema", ["connection": "dev", "pattern": "customer"])
        XCTAssertTrue(s.text.contains("public.orders.customer_id"), s.text)
        let e = try await call("explain_query", ["connection": "dev", "sql": "DELETE FROM orders WHERE id = -1"])
        XCTAssertTrue(e.text.contains("Delete on orders"), e.text)
        let schemas = try await call("list_schemas", ["connection": "dev"])
        XCTAssertTrue(schemas.text.contains("analytics"), schemas.text)
        let err = try await call("run_query", ["connection": "dev", "sql": "SELECT nope FROM orders"])
        XCTAssertTrue(err.isError && err.text.contains("42703"), err.text)
    }

    func testPGExecuteStatementTempTable() async throws {
        try requirePG()
        let r = try await call("execute_statement", ["connection": "dev",
                                                     "sql": "CREATE TEMP TABLE mcp_probe (x int); INSERT INTO mcp_probe VALUES (1), (2), (3); UPDATE mcp_probe SET x = x * 10 WHERE x > 1 RETURNING x"])
        XCTAssertFalse(r.isError, r.text)
        XCTAssertTrue(r.text.contains("Total rows affected: 5"), r.text)
        let failed = try await call("execute_statement", ["connection": "dev", "sql": "INSERT INTO mcp_probe VALUES (4); INSERT INTO mcp_probe VALUES ('x')"])
        XCTAssertTrue(failed.isError)
        // The failed batch rolled back as a whole and left the session usable.
        let count = try await call("run_query", ["connection": "dev", "sql": "SELECT count(*) AS n FROM mcp_probe"])
        XCTAssertTrue(count.text.contains("\n3\n") || count.text.contains("n\n-\n3"), count.text)
        let history = HistoryStore(url: dir.appendingPathComponent("history.sqlite")).entries()
        XCTAssertTrue(history.contains { $0.source == "mcp" && $0.sql.contains("mcp_probe") && $0.rowCount == 5 })
    }
}
