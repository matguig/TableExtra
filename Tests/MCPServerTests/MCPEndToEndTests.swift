import MTPCore
import XCTest

/// Pipes JSON-RPC lines into the built `tableextra-mcp` binary, like Claude Code does.
/// Needs MTP_TEST_PG; uses a throwaway TABLEEXTRA_HOME (under $TABLEEXTRA_HOME when set) and PGPASSWORD.
final class MCPEndToEndTests: XCTestCase {
    struct FileFormat: Codable {
        var version = 1
        var connections: [ConnectionConfig]
        var groups: [ConnectionGroup] = []
    }

    func binaryURL() throws -> URL {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let url = products.appendingPathComponent("tableextra-mcp")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw XCTSkip("tableextra-mcp not built at \(url.path); run `swift build --product tableextra-mcp`")
        }
        return url
    }

    func testStdioSession() throws {
        guard let spec = ProcessInfo.processInfo.environment["MTP_TEST_PG"] else { throw XCTSkip("MTP_TEST_PG not set") }
        let p = spec.split(separator: ":").map(String.init)
        let binary = try binaryURL()
        let base = ProcessInfo.processInfo.environment["TABLEEXTRA_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let home = base.appendingPathComponent("mcp-e2e-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let dev = ConnectionConfig(name: "e2e-dev", driver: .postgres, host: p[0], port: Int(p[1]), user: p[2], database: p[4],
                                   sslMode: .disable, environment: .development, mcpAccess: .readWrite)
        let prod = ConnectionConfig(name: "e2e-prod", driver: .postgres, host: p[0], port: Int(p[1]), user: p[2], database: p[4],
                                    sslMode: .disable, environment: .production, mcpAccess: .readWrite)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(FileFormat(connections: [dev, prod])).write(to: home.appendingPathComponent("connections.json"))

        let lines = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"e2e","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_connections","arguments":{}}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"run_query","arguments":{"connection":"e2e-dev","sql":"SELECT id, status FROM orders ORDER BY id","max_rows":3}}}"#,
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"run_query","arguments":{"connection":"e2e-dev","sql":"DELETE FROM orders"}}}"#,
            #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"execute_statement","arguments":{"connection":"e2e-prod","sql":"UPDATE products SET stock = 0 WHERE id = 1"}}}"#,
            #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"describe_table","arguments":{"connection":"e2e-dev","table":"order_items"}}}"#,
            #"{"jsonrpc":"2.0","id":8,"method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":9,"method":"nope"}"#,
        ]

        let process = Process()
        process.executableURL = binary
        var env = ProcessInfo.processInfo.environment
        env["TABLEEXTRA_HOME"] = home.path
        env["PGPASSWORD"] = p[3]
        env["TABLEEXTRA_MCP_NO_KEYCHAIN"] = "1"
        process.environment = env
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        try stdin.fileHandleForWriting.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
        try stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        var byID: [Int: [String: Any]] = [:]
        for line in String(decoding: output, as: UTF8.self).split(separator: "\n") {
            let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], "stdout must carry JSON only: \(line)")
            XCTAssertEqual(obj["jsonrpc"] as? String, "2.0")
            if let id = obj["id"] as? Int { byID[id] = obj }
        }
        XCTAssertEqual(Set(byID.keys), [1, 2, 3, 4, 5, 6, 7, 8, 9], "one response per request, none for the notification")

        func result(_ id: Int) -> [String: Any] { byID[id]?["result"] as? [String: Any] ?? [:] }
        func text(_ id: Int) -> String { ((result(id)["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "" }
        func isError(_ id: Int) -> Bool { result(id)["isError"] as? Bool ?? false }

        XCTAssertEqual(result(1)["protocolVersion"] as? String, "2025-06-18")
        XCTAssertEqual((result(1)["serverInfo"] as? [String: Any])?["name"] as? String, "tableextra")
        XCTAssertEqual((result(2)["tools"] as? [Any])?.count, MCPToolCount)
        XCTAssertTrue(text(3).contains("e2e-dev") && text(3).contains("read-only (production)"), text(3))
        XCTAssertFalse(isError(4), text(4))
        XCTAssertTrue(text(4).contains("3 rows") && text(4).contains("truncated"), text(4))
        XCTAssertTrue(isError(5) && text(5).hasPrefix("Refused"), text(5))
        XCTAssertTrue(isError(6) && text(6).contains("production"), text(6))
        XCTAssertTrue(text(7).contains("FK → public.orders(id)"), text(7))
        XCTAssertNotNil(byID[8]?["result"])
        XCTAssertEqual((byID[9]?["error"] as? [String: Any])?["code"] as? Int, -32601)

        let audit = try String(contentsOf: home.appendingPathComponent("mcp-audit.log"), encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(audit.count, 5, "one audit line per tool call")
        XCTAssertTrue(audit.contains { $0.contains(#""status":"refused""#) && $0.contains("DELETE FROM orders") })
        XCTAssertTrue(audit.allSatisfy { $0.contains(#""client":"e2e 1""#) })
        let history = HistoryStore(url: home.appendingPathComponent("history.sqlite")).entries()
        XCTAssertTrue(history.contains { $0.source == "mcp" && $0.sql.hasPrefix("SELECT id, status FROM orders") && $0.rowCount == 3 })
    }

    let MCPToolCount = 8
}
