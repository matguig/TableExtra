import Foundation
import MTPCore

/// A PostgreSQL enum type and its labels in sort order.
public struct EnumTypeDef: Hashable, Sendable, Codable, Identifiable {
    public var schema: String
    public var name: String
    public var values: [String]

    public init(schema: String, name: String, values: [String]) {
        self.schema = schema
        self.name = name
        self.values = values
    }

    public var id: String { "\(schema).\(name)" }
}

/// View or materialized view body (the SELECT, as returned by pg_get_viewdef).
public struct ViewDef: Hashable, Sendable, Codable, Identifiable {
    public var schema: String
    public var name: String
    public var kind: DBObjectKind
    public var definition: String

    public init(schema: String, name: String, kind: DBObjectKind, definition: String) {
        self.schema = schema
        self.name = name
        self.kind = kind
        self.definition = definition
    }

    public var id: String { "\(schema).\(name)" }
    public var isMaterialized: Bool { kind == .materializedView }
}

/// Everything the diff, codegen and diagram need from one schema.
public struct SchemaSnapshot: Sendable, Codable, Hashable {
    public var schema: String
    public var tables: [TableDetails]
    public var enums: [EnumTypeDef]
    public var views: [ViewDef]
    /// Domain name → base type name (udt), used by codegen.
    public var domains: [String: String]

    public init(schema: String, tables: [TableDetails], enums: [EnumTypeDef] = [], views: [ViewDef] = [], domains: [String: String] = [:]) {
        self.schema = schema
        self.tables = tables
        self.enums = enums
        self.views = views
        self.domains = domains
    }

    /// enum name → labels, the shape `TypeScriptGenerator` takes.
    public var enumMap: [String: [String]] {
        var out: [String: [String]] = [:]
        for e in enums { out[e.name] = e.values }
        return out
    }
}

/// Loads a `SchemaSnapshot` through the shared introspector plus a few PostgreSQL-only catalog queries.
public enum SchemaSnapshotLoader {
    public static func load(client: DBClient, introspector: SchemaIntrospector, schema: String,
                            includeViewDefinitions: Bool = true) async throws -> SchemaSnapshot {
        let tables = try await introspector.snapshot(schema: schema)
        guard client.config.driver == .postgres else {
            return SchemaSnapshot(schema: schema, tables: tables)
        }
        let enums = try await loadEnums(client: client, schema: schema)
        let domains = try await loadDomains(client: client, schema: schema)
        let views = includeViewDefinitions ? try await loadViews(client: client, schema: schema) : []
        return SchemaSnapshot(schema: schema, tables: tables, enums: enums, views: views, domains: domains)
    }

    public static func loadEnums(client: DBClient, schema: String) async throws -> [EnumTypeDef] {
        let r = try await client.query("""
            SELECT t.typname, string_agg(e.enumlabel, E'\\x1f' ORDER BY e.enumsortorder)
            FROM pg_type t
            JOIN pg_namespace n ON n.oid = t.typnamespace
            JOIN pg_enum e ON e.enumtypid = t.oid
            WHERE n.nspname = $1
            GROUP BY t.typname
            ORDER BY t.typname
            """, [schema])
        return r.rows.map { row in
            EnumTypeDef(schema: schema, name: row[0] ?? "", values: (row[1] ?? "").components(separatedBy: "\u{1f}"))
        }
    }

    static func loadDomains(client: DBClient, schema: String) async throws -> [String: String] {
        let r = try await client.query("""
            SELECT t.typname, bt.typname
            FROM pg_type t
            JOIN pg_namespace n ON n.oid = t.typnamespace
            JOIN pg_type bt ON bt.oid = t.typbasetype
            WHERE n.nspname = $1 AND t.typtype = 'd'
            """, [schema])
        var out: [String: String] = [:]
        for row in r.rows { if let n = row[0], let b = row[1] { out[n] = b } }
        return out
    }

    static func loadViews(client: DBClient, schema: String) async throws -> [ViewDef] {
        let r = try await client.query("""
            SELECT c.relname, c.relkind, pg_get_viewdef(c.oid, true)
            FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = $1 AND c.relkind IN ('v','m')
            ORDER BY c.relname
            """, [schema])
        return r.rows.map { row in
            ViewDef(schema: schema, name: row[0] ?? "", kind: row[1] == "m" ? .materializedView : .view, definition: row[2] ?? "")
        }
    }
}
