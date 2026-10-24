import Foundation
import MTPCore

/// Everything the tools need from the outside world; tests swap in temporary stores.
public struct MCPEnvironment: @unchecked Sendable {
    /// Saved connections, re-read on every call so edits made in the app show up without a restart.
    var connections: @Sendable () -> [ConnectionConfig]
    var secrets: @Sendable (ConnectionConfig) -> ConnectionSecrets
    var audit: AuditLog
    var history: HistoryStore?
    var statementTimeout = "30s"
    var writeTimeout = "120s"
    /// `source` of the query-history entries the tools write.
    var historySource = "mcp"

    public static func live() -> MCPEnvironment {
        // Set by the in-app Claude assistant (Claude Code backend): only that connection, read-only.
        make(only: ProcessInfo.processInfo.environment["TABLEEXTRA_MCP_ONLY"].flatMap(UUID.init(uuidString:)))
    }

    /// The in-app assistant calling the tools in-process (API backend): only `connectionID`, read-only, whatever its
    /// MCP setting, and only while the connection lets Claude query.
    public static func assistant(connectionID: UUID) -> MCPEnvironment {
        var env = make(only: connectionID)
        env.historySource = "claude"
        return env
    }

    static func make(only: UUID?) -> MCPEnvironment {
        let store = ConnectionStore.shared
        let env = ProcessInfo.processInfo.environment
        let skipKeychain = (env["TABLEEXTRA_MCP_NO_KEYCHAIN"] ?? env["MYTABLEPLUS_MCP_NO_KEYCHAIN"]) == "1"
        return MCPEnvironment(
            connections: {
                store.reload()
                guard let only else { return store.connections }
                return store.connections.filter { $0.id == only && $0.effectiveClaudeCanQuery }.map { c in
                    var c = c
                    c.mcpAccess = .readOnly
                    return c
                }
            },
            secrets: { config in
                // No password in the Keychain → libpq falls back to PGPASSWORD / ~/.pgpass on its own.
                skipKeychain ? ConnectionSecrets() : store.secrets(for: config.id)
            },
            audit: AuditLog(url: AppPaths.mcpAuditLog),
            history: HistoryStore.shared
        )
    }
}

/// One DBClient per connection (and per read-only SQLite handle) for the process lifetime.
final class ClientPool: @unchecked Sendable {
    private let lock = NSLock()
    private var clients: [String: (fingerprint: String, client: DBClient)] = [:]
    private var warmed: Set<ObjectIdentifier> = []
    private let secrets: @Sendable (ConnectionConfig) -> ConnectionSecrets

    init(secrets: @escaping @Sendable (ConnectionConfig) -> ConnectionSecrets) {
        self.secrets = secrets
    }

    /// PostgreSQL reads share the main client (they run in BEGIN READ ONLY); SQLite reads get a
    /// handle opened with SQLITE_OPEN_READONLY.
    func client(for config: ConnectionConfig, readOnly: Bool) -> DBClient {
        var effective = config
        let separateReader = readOnly && config.driver == .sqlite
        if separateReader { effective.safety = .readOnly }
        let key = "\(config.id.uuidString)|\(separateReader ? "ro" : "rw")"
        let fp = Self.fingerprint(effective)
        lock.lock()
        defer { lock.unlock() }
        if let existing = clients[key] {
            if existing.fingerprint == fp { return existing.client }
            warmed.remove(ObjectIdentifier(existing.client))
            existing.client.close()
        }
        let client = DBClient(config: effective, secrets: secrets(config), label: separateReader ? "mcp-ro" : "mcp")
        clients[key] = (fp, client)
        return client
    }

    /// True until markWarm is called for the client. PostgresDriver loads its type-name cache with PQexec the first
    /// time it meets a non-builtin type (enum, domain…); doing that in the middle of a row-capped (single-row mode)
    /// fetch discards the rest of the result. Loading it up front with a harmless query avoids that.
    func needsTypeWarmup(_ client: DBClient) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !warmed.contains(ObjectIdentifier(client))
    }

    func markWarm(_ client: DBClient) {
        lock.lock()
        warmed.insert(ObjectIdentifier(client))
        lock.unlock()
    }

    func closeAll() {
        lock.lock()
        let all = clients.values.map(\.client)
        clients.removeAll()
        lock.unlock()
        all.forEach { $0.close() }
    }

    /// Settings that change the physical connection (not the name, color or timestamps).
    static func fingerprint(_ c: ConnectionConfig) -> String {
        let opts = c.extraOptions.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        return [c.driver.rawValue, c.host, String(c.effectivePort), c.user, c.database, c.sslMode.rawValue, c.filePath,
                String(c.safety.rawValue), String(c.ssh.enabled), c.ssh.host, String(c.ssh.port), c.ssh.user, c.ssh.privateKeyPath,
                c.startupSQL, opts].joined(separator: "\u{1f}")
    }
}
