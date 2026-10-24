import Foundation
import MTPAgentTools

/// What Claude may use besides the prompt, for both backends.
public struct AIAccess: Sendable, Equatable {
    /// Application code Claude may read (never write).
    public var codeRepository: URL?
    /// Connection Claude may query, read-only (the tableextra-mcp tools, restricted to this connection).
    public var queryConnection: UUID?

    public init(codeRepository: URL? = nil, queryConnection: UUID? = nil) {
        self.codeRepository = codeRepository
        self.queryConnection = queryConnection
    }

    public static let none = AIAccess()
    public var canQuery: Bool { queryConnection != nil }
    public var usesTools: Bool { codeRepository != nil || queryConnection != nil }
}

/// Claude through the Claude API with the user's API key: the same prompts as the CLI backend, and the same read-only
/// tools, run in-process (repository reads, tableextra-mcp's database tools on one connection).
public struct ClaudeAPIAssistant: Sendable {
    public static let maxToolRounds = 24
    /// The database tools the assistant gets (never list_connections or execute_statement).
    public static let databaseToolNames = ["list_schemas", "list_tables", "describe_table", "search_schema", "run_query", "explain_query"]
    static let fallbackBeta = "server-side-fallback-2026-07-01"

    public var client: AnthropicClient
    /// Builds the database tools for a connection; tests swap it.
    var databaseTools: @Sendable (UUID) -> DatabaseToolRunner = { id in MCPDatabaseTools(connectionID: id) }

    public init(client: AnthropicClient) {
        self.client = client
    }

    public static func fromKeychain() throws -> ClaudeAPIAssistant {
        ClaudeAPIAssistant(client: try AnthropicClient.fromKeychain())
    }

    /// `effort`: low / medium / high (adaptive thinking is always on with the current models).
    public func ask(_ prompt: String, model: String, systemPrompt: String, access: AIAccess = .none,
                    effort: String = "medium") async throws -> ClaudeResponse {
        let start = Date()
        let modelID = AIModels.apiID(for: model)
        let repo = access.codeRepository.map { RepoTools(root: $0) }
        let db = access.queryConnection.map { databaseTools($0) }
        defer { db?.close() }

        var tools: [JSONValue] = []
        if repo != nil { tools += RepoTools.definitions }
        if let db { tools += db.definitions }

        var messages: [JSONValue] = [["role": "user", "content": .string(prompt)]]
        for _ in 0...Self.maxToolRounds {
            try Task.checkCancellation()
            let (body, betas) = Self.requestBody(model: modelID, system: systemPrompt, messages: messages, tools: tools, effort: effort)
            let response = try await client.createMessage(body, betas: betas)
            guard let content = response["content"]?.arrayValue else {
                throw AnthropicAPIError.invalidResponse(response.serialized())
            }
            let stop = response["stop_reason"]?.stringValue ?? ""
            if stop == "refusal" {
                throw AnthropicAPIError.refusal(category: response["stop_details"]?["category"]?.stringValue)
            }
            let calls = content.filter { $0["type"]?.stringValue == "tool_use" }
            if stop == "tool_use", !calls.isEmpty {
                // The whole assistant turn goes back unchanged (thinking and fallback blocks included).
                messages.append(["role": "assistant", "content": .array(content)])
                var results: [JSONValue] = []
                for call in calls {
                    let result = await run(call, repo: repo, db: db)
                    results.append(["type": "tool_result", "tool_use_id": call["id"] ?? .null,
                                    "content": .string(result.text), "is_error": .bool(result.isError)])
                }
                messages.append(["role": "user", "content": .array(results)])
                continue
            }
            let text = content.compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil }
                .joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                throw AnthropicAPIError.invalidResponse(stop == "max_tokens" ? "the answer hit the output limit" : "empty answer (\(stop))")
            }
            return ClaudeResponse(text: text, model: response["model"]?.stringValue ?? modelID,
                                  durationMS: Int(Date().timeIntervalSince(start) * 1000), costUSD: nil)
        }
        throw AnthropicAPIError.tooManySteps(Self.maxToolRounds)
    }

    func run(_ call: JSONValue, repo: RepoTools?, db: DatabaseToolRunner?) async -> ToolResult {
        let name = call["name"]?.stringValue ?? ""
        let input = call["input"]?.objectValue ?? [:]
        if RepoTools.names.contains(name), let repo { return repo.call(name, arguments: input) }
        if Self.databaseToolNames.contains(name), let db { return await db.call(name, arguments: input) }
        return ToolResult(text: "Tool \(name) is not available.", isError: true)
    }

    /// Request body and beta headers. The system prompt and tools are identical on every round, so the
    /// automatic cache breakpoint lets later rounds of a tool loop read them from the prompt cache.
    static func requestBody(model: String, system: String, messages: [JSONValue], tools: [JSONValue],
                            effort: String) -> (JSONValue, [String]) {
        var body: [String: JSONValue] = [
            "model": .string(model),
            "max_tokens": 16_000,
            "system": .string(system),
            "messages": .array(messages),
            "output_config": ["effort": .string(effort)],
            "cache_control": ["type": "ephemeral"],
        ]
        if !tools.isEmpty { body["tools"] = .array(tools) }
        var betas: [String] = []
        // A safety-classifier decline is re-run server-side on the model Anthropic recommends for its category.
        // Not offered for Haiku.
        if model.hasPrefix("claude-opus") || model.hasPrefix("claude-sonnet") {
            body["fallbacks"] = "default"
            betas.append(fallbackBeta)
        }
        return (.object(body), betas)
    }
}

/// tableextra-mcp's read-only database tools for one connection.
public protocol DatabaseToolRunner: Sendable {
    var definitions: [JSONValue] { get }
    func call(_ name: String, arguments: [String: JSONValue]) async -> ToolResult
    func close()
}

/// The MCP server's tools called in-process. Claude never names the connection: it is fixed here.
struct MCPDatabaseTools: DatabaseToolRunner {
    let connectionID: UUID
    let tools: MCPTools

    init(connectionID: UUID) {
        self.connectionID = connectionID
        tools = MCPTools(environment: .assistant(connectionID: connectionID))
        tools.clientName = "tableextra-assistant"
    }

    var definitions: [JSONValue] { Self.apiDefinitions(MCPTools.definitions) }

    func call(_ name: String, arguments: [String: JSONValue]) async -> ToolResult {
        var args = arguments
        args["connection"] = .string(connectionID.uuidString)
        return await tools.call(name, arguments: args)
    }

    func close() { tools.shutdown() }

    /// MCP definitions → Claude API ones: the allowed tools only, without the `connection` argument.
    static func apiDefinitions(_ mcp: [JSONValue]) -> [JSONValue] {
        mcp.compactMap { d in
            guard let name = d["name"]?.stringValue, ClaudeAPIAssistant.databaseToolNames.contains(name),
                  var schema = d["inputSchema"]?.objectValue else { return nil }
            var properties = schema["properties"]?.objectValue ?? [:]
            properties["connection"] = nil
            schema["properties"] = .object(properties)
            schema["required"] = .array((schema["required"]?.arrayValue ?? []).filter { $0.stringValue != "connection" })
            return ["name": .string(name), "description": d["description"] ?? "", "input_schema": .object(schema)]
        }
    }
}
