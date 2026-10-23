import AppKit
import MTPCore
import SwiftUI

/// What a feature module may ask of the workspace window that hosts it.
/// The app's `WorkspaceModel` implements this; features never import the app target.
@MainActor
public protocol WorkspaceContext: AnyObject {
    var connection: ConnectionConfig { get }
    /// Shared connection used for metadata and table browsing. Do not run long queries on it.
    var client: DBClient { get }
    var introspector: SchemaIntrospector { get }
    var serverInfo: ServerInfo? { get }
    var currentDatabase: String { get }
    var currentSchema: String { get }
    /// Schemas of the current database, cached by the sidebar.
    var schemas: [String] { get }

    /// A dedicated connection (long-running work, transactions). Caller closes it.
    func makeClient(label: String) -> DBClient

    func openQueryTab(title: String?, sql: String, run: Bool)
    func openTable(schema: String, name: String)
    func refreshSidebar()

    /// Applies the connection safety level (confirmation, Touch ID, read-only) before a write.
    /// Returns false when the user cancelled or the connection is read-only.
    func confirmWrite(sql: String, summary: String) async -> Bool

    func showError(_ error: Error)
    func showToast(_ message: String)

    /// Opens the Claude assistant of this workspace and asks (or pre-fills) the request.
    func askClaude(_ request: AIRequest)
}

public extension WorkspaceContext {
    var dialect: SQLDialect { client.dialect }
    var isPostgres: Bool { connection.driver == .postgres }
}

/// Connection-colored accent for headers and badges.
public extension ConnectionConfig {
    var accentColor: Color { Color(hex: effectiveColorHex) ?? .accentColor }
    var accentNSColor: NSColor { NSColor(hex: effectiveColorHex) ?? .controlAccentColor }
}
