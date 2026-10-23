import MTPCore
import MTPUIKit
import SwiftUI

// Public entry points used by the app. Keep these signatures stable.
// Pure engines (no UI) are public too: SchemaDiff, MigrationGenerator, TypeScriptGenerator, ERLayout, SchemaSnapshotLoader.

/// Compare the current schema with another connection/schema and generate a migration script.
public struct SchemaDiffView: View {
    let context: WorkspaceContext
    public init(context: WorkspaceContext) { self.context = context }
    public var body: some View { SchemaDiffScreen(context: context) }
}

/// Generate Kysely / TypeScript types (and Zod schemas) from tables.
public struct TypeScriptExportView: View {
    let context: WorkspaceContext
    let schema: String
    let tables: [String]?
    public init(context: WorkspaceContext, schema: String, tables: [String]? = nil) {
        self.context = context
        self.schema = schema
        self.tables = tables
    }
    public var body: some View { TypeScriptExportScreen(context: context, schema: schema, tables: tables) }
}

/// Entity-relationship diagram of a schema.
public struct ERDiagramView: View {
    let context: WorkspaceContext
    let schema: String
    public init(context: WorkspaceContext, schema: String) {
        self.context = context
        self.schema = schema
    }
    public var body: some View { ERDiagramScreen(context: context, schema: schema) }
}
