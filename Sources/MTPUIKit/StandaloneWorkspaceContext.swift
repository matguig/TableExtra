import Foundation
import MTPCore

/// Minimal WorkspaceContext over a single connection, for tests, previews and standalone windows.
/// Tab navigation calls are recorded instead of performed.
@MainActor
public final class StandaloneWorkspaceContext: WorkspaceContext {
    public let connection: ConnectionConfig
    public let client: DBClient
    public let introspector: SchemaIntrospector
    public var serverInfo: ServerInfo?
    public var currentDatabase: String
    public var currentSchema: String
    public var schemas: [String] = []
    private let secrets: ConnectionSecrets

    public private(set) var openedQueries: [(title: String?, sql: String, run: Bool)] = []
    public private(set) var openedTables: [(schema: String, name: String)] = []
    public private(set) var toasts: [String] = []
    public private(set) var errors: [Error] = []
    /// Answer returned by confirmWrite (tests flip it).
    public var allowWrites = true

    public init(connection: ConnectionConfig, secrets: ConnectionSecrets, schema: String? = nil) {
        self.connection = connection
        self.secrets = secrets
        self.client = DBClient(config: connection, secrets: secrets)
        self.introspector = Introspection.make(client)
        self.currentDatabase = connection.database
        self.currentSchema = schema ?? (connection.driver == .sqlite ? "main" : "public")
    }

    /// Connects and loads server info and schema list.
    public func prepare() async throws {
        serverInfo = try await client.connect()
        schemas = try await introspector.schemas(includeSystem: false)
    }

    public func makeClient(label: String) -> DBClient { client.makeSibling(label: label) }
    public func openQueryTab(title: String?, sql: String, run: Bool) { openedQueries.append((title, sql, run)) }
    public func openTable(schema: String, name: String) { openedTables.append((schema, name)) }
    public func refreshSidebar() {}
    public func confirmWrite(sql: String, summary: String) async -> Bool { allowWrites && connection.safety != .readOnly }
    public func showError(_ error: Error) { errors.append(error) }
    public func showToast(_ message: String) { toasts.append(message) }
    /// Requests sent to Claude (tests and previews inspect them).
    public var claudeRequests: [AIRequest] = []
    public func askClaude(_ request: AIRequest) { claudeRequests.append(request) }
}
