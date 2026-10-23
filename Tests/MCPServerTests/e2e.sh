#!/bin/sh
# Manual end-to-end check: pipes a JSON-RPC session into the built server.
# Usage: TABLEEXTRA_HOME=<dir with connections.json> PGPASSWORD=... Tests/MCPServerTests/e2e.sh <connection name>
set -eu
BIN="${MCP_BIN:-$(dirname "$0")/../../.build/debug/tableextra-mcp}"
CONN="${1:?connection name}"
: "${TABLEEXTRA_HOME:?set TABLEEXTRA_HOME so the real app data is never touched}"
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"e2e.sh","version":"1"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_connections","arguments":{}}}' \
  "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"list_tables\",\"arguments\":{\"connection\":\"$CONN\"}}}" \
  "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"run_query\",\"arguments\":{\"connection\":\"$CONN\",\"sql\":\"select 1 as ok\"}}}" \
  "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"run_query\",\"arguments\":{\"connection\":\"$CONN\",\"sql\":\"delete from x\"}}}" \
  | TABLEEXTRA_MCP_NO_KEYCHAIN="${TABLEEXTRA_MCP_NO_KEYCHAIN:-1}" "$BIN"
