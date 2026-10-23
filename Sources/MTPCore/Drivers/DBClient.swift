import Foundation

/// Thread-safe, async front-end for one physical connection.
/// All driver calls run on a private serial queue; `cancel()` may be called from anywhere.
public final class DBClient: @unchecked Sendable {
    public let config: ConnectionConfig
    public let dialect: SQLDialect
    private let secrets: ConnectionSecrets
    private let queue: DispatchQueue
    private var driver: DatabaseDriver?
    private var tunnel: SSHTunnel?
    private let stateLock = NSLock()
    private var _isBusy = false
    public private(set) var serverInfo: ServerInfo?

    public init(config: ConnectionConfig, secrets: ConnectionSecrets, label: String = "main") {
        self.config = config
        self.secrets = secrets
        self.dialect = SQLDialect(kind: config.driver)
        self.queue = DispatchQueue(label: "mtp.db.\(config.id.uuidString.prefix(8)).\(label)", qos: .userInitiated)
    }

    deinit {
        let d = driver
        let t = tunnel
        queue.async {
            d?.close()
            t?.stop()
        }
    }

    public var isBusy: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _isBusy
    }

    public var isConnected: Bool { driver?.isAlive ?? false }

    /// A sibling connection with the same settings (query tabs get their own session).
    public func makeSibling(label: String) -> DBClient {
        DBClient(config: config, secrets: secrets, label: label)
    }

    @discardableResult
    public func connect() async throws -> ServerInfo {
        try await perform { _ in try self.serverInfo! }
    }

    private func openIfNeeded() throws -> DatabaseDriver {
        if let driver { return driver }
        var host: String?
        var port: Int?
        if config.ssh.enabled && config.driver == .postgres {
            let t = SSHTunnel(ssh: config.ssh, remoteHost: config.host.isEmpty ? "127.0.0.1" : config.host, remotePort: config.effectivePort)
            try t.start()
            tunnel = t
            host = "127.0.0.1"
            port = t.localPort
        }
        let d = try DriverFactory.open(config, secrets: secrets, overrideHost: host, overridePort: port)
        driver = d
        serverInfo = try d.serverInfo()
        return d
    }

    /// Exclusive access to the driver; use for multi-statement work such as transactions.
    public func perform<T>(_ body: @escaping (DatabaseDriver) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            queue.async {
                self.setBusy(true)
                defer { self.setBusy(false) }
                do {
                    let d = try self.openIfNeeded()
                    cont.resume(returning: try body(d))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    public func query(_ sql: String, _ params: [String?] = [], maxRows: Int? = nil) async throws -> QueryResult {
        try await perform { try $0.execute(sql, params: params, maxRows: maxRows) }
    }

    public func query(_ statement: SQLStatementWithParams, maxRows: Int? = nil) async throws -> QueryResult {
        try await query(statement.sql, statement.params, maxRows: maxRows)
    }

    /// Runs statements in one transaction, rolling back on the first failure.
    @discardableResult
    public func transaction(_ statements: [SQLStatementWithParams]) async throws -> [QueryResult] {
        try await perform { d in
            let ownsTransaction = !d.inTransaction
            if ownsTransaction { _ = try d.execute("BEGIN", params: [], maxRows: nil) }
            var results: [QueryResult] = []
            do {
                for s in statements { results.append(try d.execute(s.sql, params: s.params, maxRows: nil)) }
                if ownsTransaction { _ = try d.execute("COMMIT", params: [], maxRows: nil) }
            } catch {
                if ownsTransaction { _ = try? d.execute("ROLLBACK", params: [], maxRows: nil) }
                throw error
            }
            return results
        }
    }

    /// Executes a write inside BEGIN … ROLLBACK and reports the affected row count (PostgreSQL only).
    public func dryRun(_ sql: String) async throws -> QueryResult {
        try await perform { d in
            guard d.kind == .postgres else { throw DatabaseError("Dry run is only available for PostgreSQL") }
            guard !d.inTransaction else { throw DatabaseError("A transaction is already open on this tab") }
            _ = try d.execute("BEGIN", params: [], maxRows: nil)
            defer { _ = try? d.execute("ROLLBACK", params: [], maxRows: nil) }
            return try d.execute(sql, params: [], maxRows: 50)
        }
    }

    public var inTransaction: Bool { driver?.inTransaction ?? false }

    public func cancel() { driver?.cancel() }

    public func close() {
        queue.async {
            self.driver?.close()
            self.driver = nil
            self.tunnel?.stop()
            self.tunnel = nil
        }
    }

    private func setBusy(_ b: Bool) {
        stateLock.lock()
        _isBusy = b
        stateLock.unlock()
    }
}
