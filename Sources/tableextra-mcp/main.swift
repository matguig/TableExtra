import Foundation
import MTPAgentTools
import MTPCore

// tableextra-mcp: stdio MCP server over the connections saved in TableExtra.
// Claude Code starts it with `claude mcp add --scope user tableextra -- <path to this binary>`.

if CommandLine.arguments.contains("--version") {
    print("tableextra-mcp \(MCPServer.version)")
    exit(0)
}
if CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h") {
    print("""
    tableextra-mcp \(MCPServer.version) — MCP server (stdio, newline-delimited JSON-RPC) for TableExtra connections.
    Data: \(AppPaths.root.path) (override with TABLEEXTRA_HOME). Audit log: \(AppPaths.mcpAuditLog.path)
    Install: claude mcp add --scope user tableextra -- \(CommandLine.arguments[0])
    """)
    exit(0)
}

// A closed pipe must surface as a write error, not kill the process mid-request.
signal(SIGPIPE, SIG_IGN)
stderrLog("started (pid \(getpid()), home \(AppPaths.root.path))")
let server = MCPServer(environment: .live())
StdioTransport(server: server).run()
HistoryStore.shared.flush()
stderrLog("stdin closed, exiting")
exit(0)
