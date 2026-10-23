import Foundation

/// One physical connection. Implementations are not thread-safe except `cancel()`;
/// callers go through `DBClient`, which serialises access on its own queue.
public protocol DatabaseDriver: AnyObject {
    var kind: DriverKind { get }
    var dialect: SQLDialect { get }
    /// True while an explicit transaction is open on this connection.
    var inTransaction: Bool { get }
    var isAlive: Bool { get }

    /// Runs one statement (or a parameter-less script) and returns the last result.
    /// `maxRows` stops fetching after that many rows and marks the result truncated.
    func execute(_ sql: String, params: [String?], maxRows: Int?) throws -> QueryResult
    func serverInfo() throws -> ServerInfo
    /// Thread-safe: interrupts the statement currently running on this connection.
    func cancel()
    func reconnect() throws
    func close()
}

public struct SQLStatementWithParams: Hashable, Sendable {
    public var sql: String
    public var params: [String?]

    public init(_ sql: String, _ params: [String?] = []) {
        self.sql = sql
        self.params = params
    }
}

public enum DriverFactory {
    public static func open(_ config: ConnectionConfig, secrets: ConnectionSecrets, overrideHost: String? = nil, overridePort: Int? = nil) throws -> DatabaseDriver {
        switch config.driver {
        case .postgres:
            return try PostgresDriver(config: config, password: secrets.password, host: overrideHost, port: overridePort)
        case .sqlite:
            return try SQLiteDriver(path: config.filePath, readOnly: config.safety == .readOnly)
        }
    }
}
