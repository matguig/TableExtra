import MTPAgentTools
import MTPCore
import XCTest
@testable import FeatureAI

/// The Claude API backend with a stubbed transport: no network, no API key. "PG" tests need MTP_TEST_PG.
final class ClaudeAPITests: XCTestCase {
    /// Answers each request with the next canned response and records what was sent.
    final class StubTransport: @unchecked Sendable {
        private let lock = NSLock()
        private var responses: [(Int, String, [String: String])]
        private(set) var requests: [URLRequest] = []

        init(_ responses: [(Int, String, [String: String])]) { self.responses = responses }

        var bodies: [JSONValue] { requests.compactMap { $0.httpBody.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } } }

        func send(_ request: URLRequest) throws -> (Data, URLResponse) {
            lock.lock(); defer { lock.unlock() }
            requests.append(request)
            guard !responses.isEmpty else { throw URLError(.cannotConnectToHost) }
            let (status, body, headers) = responses.removeFirst()
            let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (Data(body.utf8), http)
        }
    }

    func client(_ stub: StubTransport) -> AnthropicClient {
        var c = AnthropicClient(apiKey: "sk-ant-test-key", transport: { try stub.send($0) })
        c.delay = { _, _ in }
        return c
    }

    static func message(_ content: String, stop: String = "end_turn", model: String = "claude-sonnet-5-5") -> String {
        #"{"id":"msg_1","type":"message","role":"assistant","model":"\#(model)","content":\#(content),"stop_reason":"\#(stop)","usage":{"input_tokens":10,"output_tokens":5}}"#
    }

    struct FakeDatabaseTools: DatabaseToolRunner {
        let calls = LockedList()
        var definitions: [JSONValue] { MCPDatabaseTools.apiDefinitions(MCPTools.definitions) }
        func call(_ name: String, arguments: [String: JSONValue]) async -> ToolResult {
            calls.append("\(name) \(arguments["sql"]?.stringValue ?? "")")
            return ToolResult(text: "count\n-----\n42", isError: false)
        }
        func close() { calls.append("closed") }
    }

    final class LockedList: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func append(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
        var values: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    // MARK: Build selection and models

    func testBackendResolution() {
        XCTAssertEqual(AIBackend.resolve(info: nil, environment: nil), .cli)
        XCTAssertEqual(AIBackend.resolve(info: "api", environment: nil), .api)
        XCTAssertEqual(AIBackend.resolve(info: "api", environment: "cli"), .cli, "the environment wins")
        XCTAssertEqual(AIBackend.resolve(info: " API ", environment: "bogus"), .api)
        XCTAssertEqual(AIModels.apiID(for: "opus"), "claude-opus-5-5")
        XCTAssertEqual(AIModels.apiID(for: "sonnet"), "claude-sonnet-5-5")
        XCTAssertEqual(AIModels.apiID(for: "haiku"), "claude-haiku-5-5")
        XCTAssertEqual(AIModels.apiID(for: "claude-opus-4-8"), "claude-opus-4-8")
        XCTAssertEqual(AIModels.displayName("opus", backend: .api), "Opus 5.5")
        XCTAssertEqual(AIModels.displayName("opus", backend: .cli), "Opus")
        XCTAssertEqual(AnthropicAPIKey.masked("sk-ant-api03-abcdefghijklmnop"), "sk-ant-…mnop")
    }

    // MARK: Requests

    func testSimpleAnswerRequestShape() async throws {
        let stub = StubTransport([(200, Self.message(#"[{"type":"thinking","thinking":"","signature":"s"},{"type":"text","text":"```sql\nSELECT 1;\n```"}]"#), [:])])
        let assistant = ClaudeAPIAssistant(client: client(stub))
        let r = try await assistant.ask("hello", model: "sonnet", systemPrompt: "SYS")
        XCTAssertEqual(r.text, "```sql\nSELECT 1;\n```")
        XCTAssertEqual(r.model, "claude-sonnet-5-5")

        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2026-10-21")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "server-side-fallback-2026-07-01")
        let body = try XCTUnwrap(stub.bodies.first)
        XCTAssertEqual(body["model"], "claude-sonnet-5-5")
        XCTAssertEqual(body["system"], "SYS")
        XCTAssertEqual(body["fallbacks"], "default")
        XCTAssertEqual(body["output_config"]?["effort"], "medium")
        XCTAssertEqual(body["cache_control"]?["type"], "ephemeral")
        XCTAssertNil(body["tools"], "no tools without repository or query access")
        XCTAssertNil(body["temperature"])
        XCTAssertNil(body["thinking"], "adaptive thinking is the default on the current models")
    }

    func testHaikuHasNoFallback() async throws {
        let stub = StubTransport([(200, Self.message(#"[{"type":"text","text":"OK"}]"#, model: "claude-haiku-5-5"), [:])])
        _ = try await ClaudeAPIAssistant(client: client(stub)).ask("x", model: "haiku", systemPrompt: "", effort: "low")
        XCTAssertNil(stub.requests[0].value(forHTTPHeaderField: "anthropic-beta"))
        XCTAssertNil(stub.bodies[0]["fallbacks"])
        XCTAssertEqual(stub.bodies[0]["output_config"]?["effort"], "low")
    }

    func testToolLoopWithRepositoryAndDatabase() async throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("repo-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("src"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        try "export type Order = { status: 'paid' | 'open' }\n".write(to: repo.appendingPathComponent("src/order.ts"), atomically: true, encoding: .utf8)

        let round1 = Self.message(#"""
        [{"type":"thinking","thinking":"","signature":"sig1"},
         {"type":"tool_use","id":"toolu_1","name":"read_file","input":{"path":"src/order.ts"}},
         {"type":"tool_use","id":"toolu_2","name":"run_query","input":{"sql":"SELECT count(*) FROM orders"}}]
        """#, stop: "tool_use")
        let round2 = Self.message(#"[{"type":"text","text":"42 orders; status is paid or open (src/order.ts:1)."}]"#)
        let stub = StubTransport([(200, round1, [:]), (200, round2, [:])])
        var assistant = ClaudeAPIAssistant(client: client(stub))
        let fake = FakeDatabaseTools()
        assistant.databaseTools = { _ in fake }

        let r = try await assistant.ask("how many orders?", model: "opus", systemPrompt: "SYS",
                                        access: AIAccess(codeRepository: repo, queryConnection: UUID()))
        XCTAssertEqual(r.text, "42 orders; status is paid or open (src/order.ts:1).")
        XCTAssertEqual(fake.calls.values, ["run_query SELECT count(*) FROM orders", "closed"])

        let first = stub.bodies[0]
        let toolNames = first["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
        XCTAssertEqual(Set(toolNames), Set(RepoTools.names + ClaudeAPIAssistant.databaseToolNames))
        XCTAssertFalse(toolNames.contains("execute_statement") || toolNames.contains("list_connections"))
        let runQuery = try XCTUnwrap(first["tools"]?.arrayValue?.first { $0["name"] == "run_query" })
        XCTAssertNil(runQuery["input_schema"]?["properties"]?["connection"], "the connection is fixed by the app")
        XCTAssertEqual(runQuery["input_schema"]?["required"], ["sql"])

        let second = try XCTUnwrap(stub.bodies.last?["messages"]?.arrayValue)
        XCTAssertEqual(second.count, 3)
        // The assistant turn is echoed unchanged, thinking block included.
        XCTAssertEqual(second[1]["content"]?.arrayValue?.first?["signature"], "sig1")
        let results = try XCTUnwrap(second[2]["content"]?.arrayValue)
        XCTAssertEqual(results.map { $0["tool_use_id"] }, ["toolu_1", "toolu_2"])
        XCTAssertTrue(results[0]["content"]?.stringValue?.contains("1\texport type Order") == true)
        XCTAssertEqual(results[1]["content"], "count\n-----\n42")
        XCTAssertEqual(results[1]["is_error"], false)
        XCTAssertEqual(stub.bodies[0]["tools"], stub.bodies[1]["tools"], "same tools every round (prompt cache)")
    }

    func testUnknownToolIsReportedToClaude() async throws {
        let stub = StubTransport([
            (200, Self.message(#"[{"type":"tool_use","id":"toolu_9","name":"execute_statement","input":{"sql":"DELETE FROM orders"}}]"#, stop: "tool_use"), [:]),
            (200, Self.message(#"[{"type":"text","text":"I cannot write."}]"#), [:]),
        ])
        var assistant = ClaudeAPIAssistant(client: client(stub))
        let fake = FakeDatabaseTools()
        assistant.databaseTools = { _ in fake }
        _ = try await assistant.ask("delete", model: "sonnet", systemPrompt: "", access: AIAccess(queryConnection: UUID()))
        let result = try XCTUnwrap(stub.bodies[1]["messages"]?.arrayValue?.last?["content"]?.arrayValue?.first)
        XCTAssertEqual(result["is_error"], true)
        XCTAssertEqual(fake.calls.values, ["closed"], "never forwarded")
    }

    // MARK: Errors

    func testRefusalAndHTTPErrors() async throws {
        let refusal = #"{"id":"m","type":"message","role":"assistant","model":"claude-opus-5-5","content":[],"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber"}}"#
        var stub = StubTransport([(200, refusal, [:])])
        await assertThrows(AnthropicAPIError.refusal(category: "cyber")) {
            _ = try await ClaudeAPIAssistant(client: self.client(stub)).ask("x", model: "opus", systemPrompt: "")
        }
        stub = StubTransport([(401, #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#, [:])])
        await assertThrows(AnthropicAPIError.unauthorized("invalid x-api-key")) {
            _ = try await ClaudeAPIAssistant(client: self.client(stub)).ask("x", model: "opus", systemPrompt: "")
        }
        XCTAssertEqual(stub.requests.count, 1, "401 is not retried")
        stub = StubTransport([(400, #"{"type":"error","error":{"type":"invalid_request_error","message":"bad"}}"#, [:])])
        await assertThrows(AnthropicAPIError.http(status: 400, type: "invalid_request_error", message: "bad")) {
            _ = try await ClaudeAPIAssistant(client: self.client(stub)).ask("x", model: "opus", systemPrompt: "")
        }
    }

    func testRetriesOverloadAndRateLimit() async throws {
        let stub = StubTransport([
            (529, #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#, [:]),
            (429, #"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}"#, ["retry-after": "1"]),
            (200, Self.message(#"[{"type":"text","text":"OK"}]"#), [:]),
        ])
        let r = try await ClaudeAPIAssistant(client: client(stub)).ask("x", model: "sonnet", systemPrompt: "")
        XCTAssertEqual(r.text, "OK")
        XCTAssertEqual(stub.requests.count, 3)

        let exhausted = StubTransport(Array(repeating: (529, #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#, [:]), count: 3))
        await assertThrows(AnthropicAPIError.overloaded("Overloaded")) {
            _ = try await ClaudeAPIAssistant(client: self.client(exhausted)).ask("x", model: "sonnet", systemPrompt: "")
        }
    }

    func testToolRoundLimit() async throws {
        let loop = Self.message(#"[{"type":"tool_use","id":"t","name":"list_files","input":{}}]"#, stop: "tool_use")
        let stub = StubTransport(Array(repeating: (200, loop, [:]), count: ClaudeAPIAssistant.maxToolRounds + 1))
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("empty-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        await assertThrows(AnthropicAPIError.tooManySteps(ClaudeAPIAssistant.maxToolRounds)) {
            _ = try await ClaudeAPIAssistant(client: self.client(stub)).ask("x", model: "sonnet", systemPrompt: "",
                                                                           access: AIAccess(codeRepository: empty))
        }
        XCTAssertEqual(stub.requests.count, ClaudeAPIAssistant.maxToolRounds + 1)
    }

    func assertThrows(_ expected: AnthropicAPIError, file: StaticString = #filePath, line: UInt = #line,
                      _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("no error", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AnthropicAPIError, expected, file: file, line: line)
        }
    }

    // MARK: Repository tools

    func testRepoToolsStayInsideTheRoot() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("repotools-\(UUID().uuidString.prefix(6))")
        let repo = base.appendingPathComponent("repo")
        let fm = FileManager.default
        try fm.createDirectory(at: repo.appendingPathComponent("db/migrations"), withIntermediateDirectories: true)
        try fm.createDirectory(at: repo.appendingPathComponent("node_modules/pkg"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        try "secret".write(to: base.appendingPathComponent("outside.txt"), atomically: true, encoding: .utf8)
        try "CREATE TABLE orders (id int);\nALTER TABLE orders ADD status text;\n"
            .write(to: repo.appendingPathComponent("db/migrations/001_orders.sql"), atomically: true, encoding: .utf8)
        try "orders everywhere".write(to: repo.appendingPathComponent("node_modules/pkg/index.js"), atomically: true, encoding: .utf8)
        try Data([0, 1, 2, 3]).write(to: repo.appendingPathComponent("blob.bin"))
        try fm.createSymbolicLink(at: repo.appendingPathComponent("escape"), withDestinationURL: base)
        let tools = RepoTools(root: repo)

        let read = tools.call("read_file", arguments: ["path": "db/migrations/001_orders.sql", "offset": 2])
        XCTAssertFalse(read.isError)
        XCTAssertEqual(read.text, "     2\tALTER TABLE orders ADD status text;\n     3\t")
        for path in ["../outside.txt", "/etc/hosts", "escape/outside.txt"] {
            let r = tools.call("read_file", arguments: ["path": .string(path)])
            XCTAssertTrue(r.isError && r.text.contains("outside the repository"), "\(path): \(r.text)")
        }
        XCTAssertTrue(tools.call("read_file", arguments: ["path": "blob.bin"]).text.contains("binary"))

        let grep = tools.call("grep", arguments: ["pattern": "TABLE ORDERS"])
        XCTAssertEqual(grep.text, "db/migrations/001_orders.sql:1: CREATE TABLE orders (id int);\ndb/migrations/001_orders.sql:2: ALTER TABLE orders ADD status text;")
        XCTAssertEqual(tools.call("grep", arguments: ["pattern": "orders", "glob": "*.js"]).text, "No matches.", "node_modules is skipped")
        XCTAssertTrue(tools.call("grep", arguments: ["pattern": "("]).isError)

        XCTAssertEqual(tools.call("list_files", arguments: ["pattern": "**/*.sql"]).text, "db/migrations/001_orders.sql")
        XCTAssertEqual(tools.call("list_files", arguments: ["pattern": "*.{bin,sql}"]).text, "blob.bin")
        XCTAssertFalse(tools.call("list_files", arguments: [:]).text.contains("node_modules"))
    }

    // MARK: Database tools in-process (needs MTP_TEST_PG)

    func testDatabaseToolsInProcess() async throws {
        guard let spec = ProcessInfo.processInfo.environment["MTP_TEST_PG"] else { throw XCTSkip("MTP_TEST_PG not set") }
        guard ProcessInfo.processInfo.environment["TABLEEXTRA_HOME"] != nil else { throw XCTSkip("needs a throwaway TABLEEXTRA_HOME") }
        let p = spec.split(separator: ":").map(String.init)
        var config = ConnectionConfig(name: "api-tools-\(UUID().uuidString.prefix(6))", driver: .postgres, host: p[0], port: Int(p[1]),
                                      user: p[2], database: p[4], sslMode: .disable)
        config.mcpAccess = .none  // the assistant gets read-only access whatever the MCP setting
        config.claudeCanQuery = true
        setenv("PGPASSWORD", p[3], 1)
        setenv("TABLEEXTRA_MCP_NO_KEYCHAIN", "1", 1)
        defer { unsetenv("TABLEEXTRA_MCP_NO_KEYCHAIN") }
        ConnectionStore.shared.upsert(config)
        defer { ConnectionStore.shared.delete(config.id) }

        let tools = MCPDatabaseTools(connectionID: config.id)
        defer { tools.close() }
        let count = await tools.call("run_query", arguments: ["sql": "SELECT count(*) AS n FROM customers"])
        XCTAssertFalse(count.isError, count.text)
        XCTAssertTrue(count.text.contains("n"))
        let write = await tools.call("run_query", arguments: ["sql": "DELETE FROM customers"])
        XCTAssertTrue(write.isError, "writes are refused")
        let other = await tools.call("run_query", arguments: ["sql": "SELECT 1", "connection": "something else"])
        XCTAssertFalse(other.isError, "the connection argument is always replaced by the app's")

        config.claudeCanQuery = false
        ConnectionStore.shared.upsert(config)
        let refused = await MCPDatabaseTools(connectionID: config.id).call("run_query", arguments: ["sql": "SELECT 1"])
        XCTAssertTrue(refused.isError, "no tools once the connection stops allowing queries")
    }
}
