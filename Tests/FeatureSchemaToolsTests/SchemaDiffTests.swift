import MTPCore
import XCTest
@testable import FeatureSchemaTools

final class SchemaDiffTests: XCTestCase {
    func testSameSchemaUnderAnotherNameHasNoDifferences() {
        // `public` prints unqualified names, `staging` qualified ones: normalisation must hide that.
        let diff = SchemaDiff.compare(source: Fx.shop(schema: "public"), target: Fx.shop(schema: "staging"))
        XCTAssertTrue(diff.isEmpty, "\(diff.tables.map { "\($0.name): \($0.columns.map(\.summary)) \($0.indexes.map(\.name)) \($0.constraints.map(\.name))" })")
        XCTAssertEqual(diff.unchangedTables.sorted(), ["customers", "order_items", "orders", "products"])
        XCTAssertEqual(diff.sourceSchema, "public")
        XCTAssertEqual(diff.targetSchema, "staging")
    }

    func testColumnChanges() throws {
        let source = Fx.shop()
        var target = Fx.shop(schema: "stage")
        var customers = target[0]
        customers.columns.removeAll { $0.name == "metadata" }
        customers.columns[3] = Fx.col("country", "text", default: "'FR'::text", ordinal: 4)
        customers.columns[2].isNullable = true
        customers.columns[4].defaultValue = nil // created_at (index shifted by the removal)
        customers.columns.append(Fx.col("legacy_code", "text", ordinal: 9))
        target[0] = customers

        let diff = SchemaDiff.compare(source: source, target: target)
        XCTAssertEqual(diff.tables.map(\.name), ["customers"])
        let t = try XCTUnwrap(diff.table("customers"))
        XCTAssertEqual(t.change, .changed)
        let byName = Dictionary(uniqueKeysWithValues: t.columns.map { ($0.name, $0) })
        XCTAssertEqual(byName["metadata"]?.change, .added)
        XCTAssertEqual(byName["legacy_code"]?.change, .removed)
        let country = try XCTUnwrap(byName["country"])
        XCTAssertTrue(country.typeChanged)
        XCTAssertTrue(country.defaultChanged)
        XCTAssertFalse(country.nullabilityChanged)
        XCTAssertEqual(country.summary, "type text → character(2), default 'FR'::text → 'FR'::bpchar")
        XCTAssertTrue(try XCTUnwrap(byName["full_name"]).nullabilityChanged)
        let created = try XCTUnwrap(byName["created_at"])
        XCTAssertTrue(created.defaultChanged)
        XCTAssertFalse(created.typeChanged)
        XCTAssertNil(byName["email"], "unchanged columns are not listed")
        XCTAssertEqual(t.summary, "5 columns")
    }

    func testIndexChangesComparedByDefinition() throws {
        let source = Fx.shop()
        var target = Fx.shop(schema: "stage")
        var orders = target[1]
        orders.indexes.removeAll { $0.name == "orders_status_placed_idx" }
        orders.indexes.removeAll { $0.name == "orders_customer_idx" }
        // Same definition, other name → rename; different definition → changed; extra one → removed.
        orders.indexes.append(Fx.index("orders_customer_id_idx", schema: "stage", table: "orders", "btree (customer_id)", columns: ["customer_id"]))
        orders.indexes.append(Fx.index("orders_placed_idx", schema: "stage", table: "orders", "btree (placed_at)", columns: ["placed_at"]))
        target[1] = orders
        var products = target[2]
        products.indexes.append(Fx.index("products_name_idx", schema: "stage", table: "products", "btree (name)", columns: ["name"]))
        target[2] = products
        var src = source
        src[2].indexes.append(Fx.index("products_name_idx", table: "products", "btree (lower(name))", columns: ["lower(name)"]))

        let diff = SchemaDiff.compare(source: src, target: target)
        let o = try XCTUnwrap(diff.table("orders"))
        let idx = Dictionary(uniqueKeysWithValues: o.indexes.map { ($0.name, $0) })
        XCTAssertEqual(idx["orders_customer_idx"]?.change, .changed)
        XCTAssertEqual(idx["orders_customer_idx"]?.renamedFrom, "orders_customer_id_idx")
        XCTAssertEqual(idx["orders_status_placed_idx"]?.change, .added)
        XCTAssertEqual(idx["orders_placed_idx"]?.change, .removed)
        XCTAssertTrue(o.columns.isEmpty)
        XCTAssertTrue(o.constraints.isEmpty, "constraint-backed indexes are not reported as indexes")

        let p = try XCTUnwrap(diff.table("products"))
        XCTAssertEqual(p.indexes.map(\.change), [.changed])
        XCTAssertNil(p.indexes[0].renamedFrom)
    }

    func testConstraintChanges() throws {
        let source = Fx.shop()
        var target = Fx.shop(schema: "stage")
        target[1].constraints.removeAll { $0.kind == .foreignKey } // orders FK missing
        target[2].constraints = target[2].constraints.map { c in
            var c = c
            if c.name == "products_price_check" { c.definition = "CHECK (price > 0::numeric)" }
            return c
        }
        target[2].constraints.removeAll { $0.name == "products_sku_key" }
        target[2].indexes.removeAll { $0.name == "products_sku_key" }
        target[2].constraints.append(ConstraintDef(name: "products_name_key", kind: .unique, columns: ["name"], definition: "UNIQUE (name)"))

        let diff = SchemaDiff.compare(source: source, target: target)
        let orders = try XCTUnwrap(diff.table("orders"))
        XCTAssertEqual(orders.constraints.map(\.name), ["orders_customer_id_fkey"])
        XCTAssertEqual(orders.constraints.first?.change, .added)
        XCTAssertEqual(orders.constraints.first?.kind, .foreignKey)

        let products = try XCTUnwrap(diff.table("products"))
        let c = Dictionary(uniqueKeysWithValues: products.constraints.map { ($0.name, $0) })
        XCTAssertEqual(c["products_price_check"]?.change, .changed)
        XCTAssertEqual(c["products_sku_key"]?.change, .added)
        XCTAssertEqual(c["products_name_key"]?.change, .removed)
    }

    func testTablesAddedAndRemoved() {
        let source = Fx.shop()
        var target = Array(Fx.shop(schema: "stage").prefix(3)) // no order_items
        target.append(Fx.table("old_stuff", schema: "stage", [Fx.col("id", "integer", udt: "int4", nullable: false)]))
        // Views are not part of the table diff.
        target.append(Fx.table("some_view", schema: "stage", kind: .view, [Fx.col("x", "integer", udt: "int4")]))

        let diff = SchemaDiff.compare(source: source, target: target)
        XCTAssertEqual(diff.tables.map(\.name), ["old_stuff", "order_items"])
        XCTAssertEqual(diff.table("order_items")?.change, .added)
        XCTAssertEqual(diff.table("old_stuff")?.change, .removed)
        XCTAssertTrue(diff.views.isEmpty)
    }

    func testEnumAndViewDiff() throws {
        let src = SchemaSnapshot(schema: "public", tables: Fx.shop(),
                                 enums: [EnumTypeDef(schema: "public", name: "order_status", values: ["pending", "paid", "shipped", "cancelled"]),
                                         EnumTypeDef(schema: "public", name: "role", values: ["admin", "user"])],
                                 views: [ViewDef(schema: "public", name: "v_orders", kind: .view, definition: " SELECT o.id\n   FROM orders o;")])
        let dst = SchemaSnapshot(schema: "stage", tables: Fx.shop(schema: "stage"),
                                 enums: [EnumTypeDef(schema: "stage", name: "order_status", values: ["pending", "shipped", "refunded"]),
                                         EnumTypeDef(schema: "stage", name: "legacy", values: ["a"])],
                                 views: [ViewDef(schema: "stage", name: "v_orders", kind: .view, definition: " SELECT o.id\n   FROM stage.orders o;"),
                                         ViewDef(schema: "stage", name: "v_old", kind: .view, definition: " SELECT 1;")])
        let diff = SchemaDiff.compare(source: src, target: dst)
        let e = Dictionary(uniqueKeysWithValues: diff.enums.map { ($0.name, $0) })
        XCTAssertEqual(e["role"]?.change, .added)
        XCTAssertEqual(e["legacy"]?.change, .removed)
        let status = try XCTUnwrap(e["order_status"])
        XCTAssertEqual(status.addedValues, ["paid", "cancelled"])
        XCTAssertEqual(status.removedValues, ["refunded"])
        XCTAssertFalse(status.orderChanged)
        XCTAssertEqual(diff.views.map(\.name), ["v_old"], "v_orders differs only by schema qualification")
        XCTAssertEqual(diff.views.first?.change, .removed)
        XCTAssertTrue(diff.sourceEnumNames.contains("order_status"))
    }

    func testNormalizer() {
        let s: Set<String> = ["public", "My Schema"]
        XCTAssertEqual(SQLNormalizer.normalize("nextval('public.seq'::regclass)", stripping: s), "nextval('seq'::regclass)")
        XCTAssertEqual(SQLNormalizer.normalize("REFERENCES \"My Schema\".t(id)", stripping: s), "REFERENCES t(id)")
        XCTAssertEqual(SQLNormalizer.normalize("x_public.t", stripping: s), "x_public.t", "only whole identifiers")
        let idx = IndexDef(name: "a", columns: ["x"], isUnique: true, definition: "CREATE UNIQUE INDEX a ON public.t USING btree (x) WHERE (x > 0)")
        XCTAssertEqual(SQLNormalizer.indexKey(idx, stripping: s), "UNIQUE btree (x) WHERE (x > 0)")
        XCTAssertEqual(sequenceName(inDefault: "nextval('public.orders_id_seq'::regclass)"), "orders_id_seq")
        XCTAssertNil(sequenceName(inDefault: "now()"))
    }
}
