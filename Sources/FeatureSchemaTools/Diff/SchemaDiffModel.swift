import Foundation
import MTPCore
import MTPUIKit
import SwiftUI
import UniformTypeIdentifiers

/// One row of the change list.
struct DiffItem: Identifiable, Hashable {
    enum Kind: Int, Hashable, CaseIterable {
        case enumType, table, view

        var title: String {
            switch self {
            case .enumType: return "Types"
            case .table: return "Tables"
            case .view: return "Views"
            }
        }
    }

    var kind: Kind
    var name: String
    var change: DiffChange
    var summary: String
    var symbol: String

    var id: String { "\(kind.rawValue):\(name)" }
}

@MainActor
final class SchemaDiffModel: ObservableObject {
    let context: WorkspaceContext
    /// Saved connections usable as target (same driver, current one excluded).
    let otherConnections: [ConnectionConfig]
    private let secrets: (ConnectionConfig) -> ConnectionSecrets

    @Published var sourceSchema: String
    @Published var targetConnectionID: UUID? {
        didSet { if oldValue != targetConnectionID { Task { await loadTargetSchemas() } } }
    }
    @Published var targetSchema: String
    @Published private(set) var targetSchemas: [String]
    @Published private(set) var loadingTargetSchemas = false
    @Published private(set) var isComparing = false
    @Published var errorMessage: String?
    @Published private(set) var result: SchemaDiffResult?
    @Published private(set) var sourceSnapshot: SchemaSnapshot?
    @Published private(set) var targetSnapshot: SchemaSnapshot?
    /// Connection/schema labels of the last comparison.
    @Published private(set) var comparedLabels: (source: String, target: String) = ("", "")
    @Published private(set) var comparedTargetIsCurrent = true
    @Published var options = MigrationOptions()
    @Published var filterText = ""
    @Published var changeFilter: DiffChange?
    @Published var selection: String?

    init(context: WorkspaceContext, connections: [ConnectionConfig]? = nil,
         secrets: ((ConnectionConfig) -> ConnectionSecrets)? = nil) {
        self.context = context
        let all = connections ?? ConnectionStore.shared.connections
        self.otherConnections = all.filter { $0.driver == context.connection.driver && $0.id != context.connection.id }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        self.secrets = secrets ?? { ConnectionStore.shared.secrets(for: $0.id) }
        let schemas = context.schemas.isEmpty ? [context.currentSchema] : context.schemas
        self.sourceSchema = schemas.contains(context.currentSchema) ? context.currentSchema : schemas[0]
        self.targetSchemas = schemas
        self.targetSchema = schemas.first { $0 != context.currentSchema } ?? context.currentSchema
    }

    var sourceSchemas: [String] { context.schemas.isEmpty ? [context.currentSchema] : context.schemas }

    var targetConnection: ConnectionConfig {
        otherConnections.first { $0.id == targetConnectionID } ?? context.connection
    }

    var targetIsCurrent: Bool { targetConnectionID == nil || targetConnectionID == context.connection.id }

    var canCompare: Bool { !isComparing && !(targetIsCurrent && sourceSchema == targetSchema) && !targetSchema.isEmpty }

    func label(_ c: ConnectionConfig, schema: String) -> String {
        "\(c.name.isEmpty ? c.subtitle : c.name) · \(schema)"
    }

    // MARK: Target

    func loadTargetSchemas() async {
        guard !targetIsCurrent else {
            targetSchemas = sourceSchemas
            if !targetSchemas.contains(targetSchema) { targetSchema = targetSchemas.first { $0 != sourceSchema } ?? sourceSchema }
            return
        }
        let config = targetConnection
        loadingTargetSchemas = true
        defer { loadingTargetSchemas = false }
        let client = DBClient(config: config, secrets: secrets(config), label: "schema-diff")
        defer { client.close() }
        do {
            try await client.connect()
            let schemas = try await Introspection.make(client).schemas(includeSystem: false)
            guard targetConnection.id == config.id else { return }
            targetSchemas = schemas
            if !schemas.contains(targetSchema) {
                targetSchema = schemas.contains(sourceSchema) ? sourceSchema : (schemas.first ?? "")
            }
            errorMessage = nil
        } catch {
            targetSchemas = []
            errorMessage = "\(config.name): \(error.localizedDescription)"
        }
    }

    /// Swaps source and target schemas (same connection only).
    func swap() {
        guard targetIsCurrent else { return }
        let s = sourceSchema
        sourceSchema = targetSchema
        targetSchema = s
    }

    // MARK: Compare

    func compare() async {
        guard canCompare else { return }
        isComparing = true
        errorMessage = nil
        defer { isComparing = false }
        do {
            let src = try await SchemaSnapshotLoader.load(client: context.client, introspector: context.introspector, schema: sourceSchema)
            let dst: SchemaSnapshot
            let config = targetConnection
            if targetIsCurrent {
                dst = try await SchemaSnapshotLoader.load(client: context.client, introspector: context.introspector, schema: targetSchema)
            } else {
                let client = DBClient(config: config, secrets: secrets(config), label: "schema-diff")
                defer { client.close() }
                try await client.connect()
                dst = try await SchemaSnapshotLoader.load(client: client, introspector: Introspection.make(client), schema: targetSchema)
            }
            sourceSnapshot = src
            targetSnapshot = dst
            comparedLabels = (label(context.connection, schema: sourceSchema), label(config, schema: targetSchema))
            comparedTargetIsCurrent = targetIsCurrent
            let r = SchemaDiff.compare(source: src, target: dst)
            result = r
            if selection == nil || !items.contains(where: { $0.id == selection }) { selection = items.first?.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Derived

    var script: MigrationScript? {
        result.map { MigrationGenerator.generate($0, dialect: context.dialect, options: options) }
    }

    var migrationSQL: String { script?.sql ?? "" }

    var allItems: [DiffItem] {
        guard let r = result else { return [] }
        var out: [DiffItem] = []
        out += r.enums.map { DiffItem(kind: .enumType, name: $0.name, change: $0.change, summary: $0.summary, symbol: DBObjectKind.type.symbolName) }
        out += r.tables.map { DiffItem(kind: .table, name: $0.name, change: $0.change, summary: $0.summary, symbol: DBObjectKind.table.symbolName) }
        out += r.views.map { v in
            DiffItem(kind: .view, name: v.name, change: v.change, summary: v.kind == .materializedView ? "materialized view" : "view", symbol: v.kind.symbolName)
        }
        return out
    }

    var items: [DiffItem] {
        let q = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        return allItems.filter { item in
            (changeFilter == nil || item.change == changeFilter) && (q.isEmpty || item.name.lowercased().contains(q))
        }
    }

    func count(_ change: DiffChange) -> Int { allItems.filter { $0.change == change }.count }

    var selectedItem: DiffItem? { allItems.first { $0.id == selection } }

    /// Source / target DDL of the selected object, built from the snapshots (no extra queries).
    func ddl(for item: DiffItem) -> (source: String, target: String) {
        guard let r = result else { return ("", "") }
        let missing = "-- (does not exist)"
        switch item.kind {
        case .table:
            let d = r.table(item.name)
            let sd = SQLDialect(kind: context.connection.driver)
            let td = SQLDialect(kind: targetConnection.driver)
            return (d?.source.map { DDLWriter.createTable($0, dialect: sd) } ?? missing,
                    d?.target.map { DDLWriter.createTable($0, dialect: td) } ?? missing)
        case .enumType:
            let e = r.enums.first { $0.name == item.name }
            func ddl(_ t: EnumTypeDef?) -> String {
                guard let t else { return missing }
                return "CREATE TYPE \(context.dialect.quoteIdentIfNeeded(t.schema)).\(context.dialect.quoteIdentIfNeeded(t.name)) AS ENUM (\n"
                    + t.values.map { "  " + context.dialect.quoteLiteral($0) }.joined(separator: ",\n") + "\n);"
            }
            return (ddl(e?.source), ddl(e?.target))
        case .view:
            let v = r.views.first { $0.name == item.name }
            func ddl(_ v: ViewDef?) -> String {
                guard let v else { return missing }
                let kw = v.isMaterialized ? "MATERIALIZED VIEW" : "VIEW"
                return "CREATE \(kw) \(context.dialect.quoteIdentIfNeeded(v.schema)).\(context.dialect.quoteIdentIfNeeded(v.name)) AS\n\(v.definition)"
            }
            return (ddl(v?.source), ddl(v?.target))
        }
    }

    // MARK: Actions

    func copyMigration() {
        Pasteboard.copy(migrationSQL)
        context.showToast("Migration copied")
    }

    func saveMigration() {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let name = "migration-\(result?.targetSchema ?? targetSchema)-\(f.string(from: Date())).sql"
        FilePanels.save(migrationSQL, suggestedName: name, types: [UTType(filenameExtension: "sql") ?? .plainText])
    }

    func openInQueryTab() {
        guard comparedTargetIsCurrent, let r = result else { return }
        context.openQueryTab(title: "Migration → \(r.targetSchema)", sql: migrationSQL, run: false)
    }
}
