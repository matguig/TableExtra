import Foundation
import MTPCore

/// JSON-RPC 2.0 / MCP request handling, independent of the transport (tests call it directly).
public final class MCPServer: @unchecked Sendable {
    static let name = "tableextra"
    public static let version = "1.0.0"
    /// Newest first; the client's version is echoed when listed here.
    static let supportedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    static let instructions = """
        tableextra-mcp exposes the database connections saved in TableExtra (PostgreSQL, SQLite).
        Start with list_connections, then use list_tables, describe_table or search_schema to learn the schema before writing SQL.
        run_query is read-only: PostgreSQL queries run in a READ ONLY transaction with a 30 s timeout and are rolled back.
        execute_statement writes only on non-production connections whose MCP access is “Read & write”.
        Every call is written to the TableExtra audit log and query history.
        """

    enum ErrorCode {
        static let parse = -32700
        static let invalidRequest = -32600
        static let methodNotFound = -32601
        static let invalidParams = -32602
        static let internalError = -32603
    }

    let tools: MCPTools
    private let lock = NSLock()
    private var _protocolVersion: String?

    init(tools: MCPTools) { self.tools = tools }

    public convenience init(environment: MCPEnvironment) {
        self.init(tools: MCPTools(environment: environment))
    }

    var protocolVersion: String? {
        lock.lock(); defer { lock.unlock() }
        return _protocolVersion
    }

    func shutdown() { tools.shutdown() }

    /// One line in, at most one line out (nil for notifications).
    func handle(line: String) async -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let message = try? JSONValue.parse(trimmed) else {
            return Self.error(id: .null, code: ErrorCode.parse, message: "Parse error: invalid JSON").serialized()
        }
        if case .array(let batch) = message {
            guard !batch.isEmpty else { return Self.error(id: .null, code: ErrorCode.invalidRequest, message: "Empty batch").serialized() }
            var responses: [JSONValue] = []
            for m in batch {
                if let r = await handle(message: m) { responses.append(r) }
            }
            return responses.isEmpty ? nil : JSONValue.array(responses).serialized()
        }
        return await handle(message: message)?.serialized()
    }

    func handle(message: JSONValue) async -> JSONValue? {
        guard case .object(let obj) = message else {
            return Self.error(id: .null, code: ErrorCode.invalidRequest, message: "Invalid Request: expected a JSON object")
        }
        let id = obj["id"]
        guard let method = obj["method"]?.stringValue else {
            // A response to a server-initiated request (we never send any) or garbage.
            if id != nil, obj["result"] != nil || obj["error"] != nil { return nil }
            return Self.error(id: id ?? .null, code: ErrorCode.invalidRequest, message: "Invalid Request: missing method")
        }
        let params = obj["params"] ?? .object([:])
        guard let id else {
            handleNotification(method, params)
            return nil
        }
        switch method {
        case "initialize":
            return Self.result(id: id, initialize(params))
        case "ping":
            return Self.result(id: id, .object([:]))
        case "tools/list":
            return Self.result(id: id, ["tools": .array(MCPTools.definitions)])
        case "tools/call":
            guard let name = params["name"]?.stringValue else {
                return Self.error(id: id, code: ErrorCode.invalidParams, message: "Invalid params: missing tool name")
            }
            guard MCPTools.names.contains(name) else {
                return Self.error(id: id, code: ErrorCode.invalidParams, message: "Unknown tool: \(name)")
            }
            let arguments = params["arguments"] ?? .object([:])
            guard arguments.objectValue != nil || arguments.isNull else {
                return Self.error(id: id, code: ErrorCode.invalidParams, message: "Invalid params: arguments must be an object")
            }
            let result = await tools.call(name, arguments: arguments.objectValue ?? [:])
            return Self.result(id: id, result.json)
        default:
            return Self.error(id: id, code: ErrorCode.methodNotFound, message: "Method not found: \(method)")
        }
    }

    func initialize(_ params: JSONValue) -> JSONValue {
        let requested = params["protocolVersion"]?.stringValue
        let version = requested.flatMap { Self.supportedProtocolVersions.contains($0) ? $0 : nil } ?? Self.supportedProtocolVersions[0]
        lock.lock()
        _protocolVersion = version
        lock.unlock()
        if let client = params["clientInfo"]?["name"]?.stringValue {
            let v = params["clientInfo"]?["version"]?.stringValue
            tools.clientName = v.map { "\(client) \($0)" } ?? client
        }
        return [
            "protocolVersion": .string(version),
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": .string(Self.name), "title": "TableExtra", "version": .string(Self.version)],
            "instructions": .string(Self.instructions),
        ]
    }

    func handleNotification(_ method: String, _ params: JSONValue) {
        switch method {
        case "notifications/initialized", "notifications/cancelled", "notifications/roots/list_changed":
            break // cancellation is handled by the transport, which owns the running tasks
        default:
            stderrLog("ignoring notification \(method)")
        }
    }

    static func result(id: JSONValue, _ result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func error(id: JSONValue, code: Int, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .int(code), "message": .string(message)]]
    }
}

/// Newline-delimited JSON-RPC over stdin/stdout. Reads with a blocking loop; each request runs in its own task
/// so a slow query never blocks `ping` or a cancellation.
public final class StdioTransport: @unchecked Sendable {
    let server: MCPServer
    private let output: FileHandle
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var running: [JSONValue: Task<Void, Never>] = [:]
    private let group = DispatchGroup()

    public init(server: MCPServer, output: FileHandle = .standardOutput) {
        self.server = server
        self.output = output
    }

    /// Returns at end of input, after in-flight requests have answered.
    public func run() {
        while let line = readLine(strippingNewline: true) {
            receive(line)
        }
        group.wait()
        server.shutdown()
    }

    func receive(_ line: String) {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard let message = try? JSONValue.parse(line) else {
            write(MCPServer.error(id: .null, code: MCPServer.ErrorCode.parse, message: "Parse error: invalid JSON").serialized())
            return
        }
        if message["method"]?.stringValue == "notifications/cancelled", let requestID = message["params"]?["requestId"] {
            stateLock.lock()
            let task = running[requestID]
            stateLock.unlock()
            task?.cancel()
            return
        }
        let id = message["method"] != nil ? message["id"] : nil
        group.enter()
        stateLock.lock()
        let task = Task.detached { [self] in
            let response: String?
            if case .array = message {
                response = await server.handle(line: line)
            } else {
                response = await server.handle(message: message)?.serialized()
            }
            if let id { finished(id) }
            // A cancelled request gets no response (MCP cancellation rules).
            if let response, !Task.isCancelled { write(response) }
            group.leave()
        }
        if let id { running[id] = task }
        stateLock.unlock()
    }

    private func finished(_ id: JSONValue) {
        stateLock.lock()
        running[id] = nil
        stateLock.unlock()
    }

    func write(_ line: String) {
        writeLock.lock()
        defer { writeLock.unlock() }
        do {
            try output.write(contentsOf: Data((line + "\n").utf8))
        } catch {
            stderrLog("cannot write to stdout: \(error.localizedDescription)")
        }
    }
}
