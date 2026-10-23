import Foundation
import MTPCore
import XCTest
@testable import FeatureSchemaTools

/// Small builders for synthetic catalog data.
enum Fx {
    static func col(_ name: String, _ type: String, udt: String? = nil, nullable: Bool = true, default def: String? = nil,
                    identity: Bool = false, ordinal: Int = 0, enumValues: [String]? = nil, comment: String? = nil) -> ColumnDef {
        ColumnDef(name: name, dataType: type, udtName: udt ?? type, isNullable: nullable, defaultValue: def, isIdentity: identity,
                  comment: comment, ordinal: ordinal, enumValues: enumValues)
    }

    static func pk(_ table: String, _ cols: [String]) -> ConstraintDef {
        ConstraintDef(name: "\(table)_pkey", kind: .primaryKey, columns: cols, definition: "PRIMARY KEY (\(cols.joined(separator: ", ")))")
    }

    static func fk(_ name: String, _ cols: [String], schema: String = "public", ref: String, _ refCols: [String], onDelete: String? = nil,
                   qualified: Bool = false) -> ConstraintDef {
        let target = qualified ? "\(schema).\(ref)" : ref
        let def = "FOREIGN KEY (\(cols.joined(separator: ", "))) REFERENCES \(target)(\(refCols.joined(separator: ", ")))" + (onDelete.map { " ON DELETE \($0)" } ?? "")
        return ConstraintDef(name: name, kind: .foreignKey, columns: cols, definition: def,
                             foreignKey: ForeignKeyRef(constraintName: name, columns: cols, refSchema: schema, refTable: ref, refColumns: refCols, onDelete: onDelete))
    }

    static func index(_ name: String, schema: String = "public", table: String, _ body: String, columns: [String], unique: Bool = false) -> IndexDef {
        IndexDef(name: name, columns: columns, isUnique: unique, definition: "CREATE \(unique ? "UNIQUE " : "")INDEX \(name) ON \(schema).\(table) USING \(body)")
    }

    static func table(_ name: String, schema: String = "public", kind: DBObjectKind = .table, _ columns: [ColumnDef],
                      indexes: [IndexDef] = [], constraints: [ConstraintDef] = [], comment: String? = nil) -> TableDetails {
        var cols = columns
        for i in cols.indices where cols[i].ordinal == 0 { cols[i].ordinal = i + 1 }
        let pkCols = Set(constraints.first { $0.kind == .primaryKey }?.columns ?? [])
        for i in cols.indices {
            cols[i].isPrimaryKey = pkCols.contains(cols[i].name)
            cols[i].foreignKey = constraints.first { $0.kind == .foreignKey && $0.columns.contains(cols[i].name) }?.foreignKey
        }
        var idx = indexes
        for c in constraints where c.kind == .primaryKey || c.kind == .unique {
            idx.insert(IndexDef(name: c.name, columns: c.columns, isUnique: true, isPrimary: c.kind == .primaryKey,
                                definition: "CREATE UNIQUE INDEX \(c.name) ON \(schema).\(name) USING btree (\(c.columns.joined(separator: ", ")))"), at: 0)
        }
        return TableDetails(object: DBObject(schema: schema, name: name, kind: kind, comment: comment), columns: cols, indexes: idx, constraints: constraints)
    }

    /// Shop-like schema as introspected from `public` (unqualified names visible on the search_path).
    static func shop(schema: String = "public") -> [TableDetails] {
        let q = schema == "public" ? "" : "\(schema)."
        let status = ["pending", "paid", "shipped", "cancelled"]
        return [
            table("customers", schema: schema, [
                col("id", "bigint", udt: "int8", nullable: false, default: "nextval('\(q)customers_id_seq'::regclass)"),
                col("email", "text", nullable: false, comment: "Login email"),
                col("full_name", "text", nullable: false),
                col("country", "character(2)", udt: "bpchar", default: "'FR'::bpchar"),
                col("metadata", "jsonb", default: "'{}'::jsonb"),
                col("created_at", "timestamp with time zone", udt: "timestamptz", nullable: false, default: "now()"),
            ], constraints: [pk("customers", ["id"]),
                             ConstraintDef(name: "customers_email_key", kind: .unique, columns: ["email"], definition: "UNIQUE (email)")]),
            table("orders", schema: schema, [
                col("id", "bigint", udt: "int8", nullable: false, default: "nextval('\(q)orders_id_seq'::regclass)"),
                col("customer_id", "bigint", udt: "int8", nullable: false),
                col("status", "\(q)order_status", udt: "order_status", nullable: false, default: "'pending'::\(q)order_status", enumValues: status),
                col("total", "numeric(12,2)", udt: "numeric", nullable: false, default: "0"),
                col("placed_at", "timestamp with time zone", udt: "timestamptz", nullable: false, default: "now()"),
                col("shipped_on", "date"),
            ], indexes: [index("orders_customer_idx", schema: schema, table: "orders", "btree (customer_id)", columns: ["customer_id"]),
                         index("orders_status_placed_idx", schema: schema, table: "orders", "btree (status, placed_at DESC)", columns: ["status", "placed_at"])],
               constraints: [pk("orders", ["id"]), fk("orders_customer_id_fkey", ["customer_id"], schema: schema, ref: "customers", ["id"], onDelete: "CASCADE", qualified: !q.isEmpty)]),
            table("products", schema: schema, [
                col("id", "integer", udt: "int4", nullable: false, default: "nextval('\(q)products_id_seq'::regclass)"),
                col("sku", "text", nullable: false),
                col("name", "text", nullable: false),
                col("price", "numeric(10,2)", udt: "numeric", nullable: false),
                col("stock", "integer", udt: "int4", nullable: false, default: "0"),
                col("tags", "text[]", udt: "_text", default: "'{}'::text[]"),
                col("is_active", "boolean", udt: "bool", nullable: false, default: "true"),
            ], constraints: [pk("products", ["id"]),
                             ConstraintDef(name: "products_sku_key", kind: .unique, columns: ["sku"], definition: "UNIQUE (sku)"),
                             ConstraintDef(name: "products_price_check", kind: .check, columns: ["price"], definition: "CHECK (price >= 0::numeric)")]),
            table("order_items", schema: schema, [
                col("order_id", "bigint", udt: "int8", nullable: false),
                col("product_id", "integer", udt: "int4", nullable: false),
                col("quantity", "integer", udt: "int4", nullable: false, default: "1"),
                col("unit_price", "numeric(10,2)", udt: "numeric", nullable: false),
            ], constraints: [pk("order_items", ["order_id", "product_id"]),
                             fk("order_items_order_id_fkey", ["order_id"], schema: schema, ref: "orders", ["id"], onDelete: "CASCADE", qualified: !q.isEmpty),
                             fk("order_items_product_id_fkey", ["product_id"], schema: schema, ref: "products", ["id"], qualified: !q.isEmpty)]),
        ]
    }
}

/// Test database access: MTP_TEST_PG="host:port:user:password:db".
enum TestDB {
    static func config() throws -> (ConnectionConfig, ConnectionSecrets) {
        guard let spec = ProcessInfo.processInfo.environment["MTP_TEST_PG"] else { throw XCTSkip("MTP_TEST_PG not set") }
        let p = spec.split(separator: ":").map(String.init)
        let c = ConnectionConfig(name: "shop (test)", driver: .postgres, host: p[0], port: Int(p[1]), user: p[2], database: p[4],
                                 sslMode: .disable, environment: .local)
        return (c, ConnectionSecrets(password: p[3]))
    }

    static func client() throws -> DBClient {
        let (c, s) = try config()
        return DBClient(config: c, secrets: s)
    }
}

extension String {
    func lines() -> [String] { components(separatedBy: "\n") }

    /// Index of the first line containing `needle` (fails the test when missing).
    func lineIndex(_ needle: String, file: StaticString = #filePath, line: UInt = #line) -> Int {
        guard let i = lines().firstIndex(where: { $0.contains(needle) }) else {
            XCTFail("missing line containing: \(needle)", file: file, line: line)
            return -1
        }
        return i
    }
}
