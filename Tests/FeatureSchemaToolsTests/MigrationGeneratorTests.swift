import MTPCore
import XCTest
@testable import FeatureSchemaTools

final class MigrationGeneratorTests: XCTestCase {
    /// Source = full shop in `public`; target = a degraded copy in `stage`.
    func makeDiff() -> SchemaDiffResult {
        var target = Array(Fx.shop(schema: "stage").prefix(3)) // order_items missing
        target[0].columns.removeAll { $0.name == "metadata" }
        target[0].columns[3] = Fx.col("country", "text", default: "'FR'::text", ordinal: 4)
        target[0].columns.append(Fx.col("legacy_code", "text", ordinal: 9))
        target[0].columns[2].isNullable = true
        target[1].constraints.removeAll { $0.kind == .foreignKey }
        target[1].indexes.removeAll { $0.name == "orders_status_placed_idx" }
        target[2].indexes.append(Fx.index("products_name_idx", schema: "stage", table: "products", "btree (name)", columns: ["name"]))
        target.append(Fx.table("old_stuff", schema: "stage", [Fx.col("id", "integer", udt: "int4", nullable: false)]))
        target.append(Fx.table("old_child", schema: "stage", [Fx.col("stuff_id", "integer", udt: "int4")],
                               constraints: [Fx.fk("old_child_stuff_fkey", ["stuff_id"], schema: "stage", ref: "old_stuff", ["id"], qualified: true)]))
        let src = SchemaSnapshot(schema: "public", tables: Fx.shop(),
                                 enums: [EnumTypeDef(schema: "public", name: "order_status", values: ["pending", "paid", "shipped", "cancelled"])])
        let dst = SchemaSnapshot(schema: "stage", tables: target,
                                 enums: [EnumTypeDef(schema: "stage", name: "order_status", values: ["pending", "paid", "shipped"]),
                                         EnumTypeDef(schema: "stage", name: "old_enum", values: ["x"])])
        return SchemaDiff.compare(source: src, target: dst)
    }

    func testOrdering() {
        let sql = MigrationGenerator.generate(makeDiff()).sql
        let begin = sql.lineIndex("BEGIN;")
        let search = sql.lineIndex("SET LOCAL search_path TO stage, public;")
        let enumValue = sql.lineIndex("ALTER TYPE stage.order_status ADD VALUE IF NOT EXISTS 'cancelled' AFTER 'shipped';")
        let createTable = sql.lineIndex("CREATE TABLE stage.order_items (")
        let addColumn = sql.lineIndex("ALTER TABLE stage.customers ADD COLUMN metadata jsonb DEFAULT '{}'::jsonb;")
        let alterType = sql.lineIndex("ALTER TABLE stage.customers ALTER COLUMN country TYPE character(2) USING country::character(2);")
        let setNotNull = sql.lineIndex("ALTER TABLE stage.customers ALTER COLUMN full_name SET NOT NULL;")
        let createIndex = sql.lineIndex("CREATE INDEX orders_status_placed_idx ON stage.orders USING btree (status, placed_at DESC);")
        let fkOrders = sql.lineIndex("ALTER TABLE stage.orders ADD CONSTRAINT orders_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES stage.customers(id) ON DELETE CASCADE;")
        let fkItems = sql.lineIndex("ALTER TABLE stage.order_items ADD CONSTRAINT order_items_order_id_fkey FOREIGN KEY (order_id) REFERENCES stage.orders(id) ON DELETE CASCADE;")
        let commit = sql.lines().lastIndex(of: "COMMIT;") ?? -1
        XCTAssertLessThan(begin, search)
        XCTAssertLessThan(search, enumValue)
        XCTAssertLessThan(enumValue, createTable)
        XCTAssertLessThan(createTable, addColumn)
        XCTAssertLessThan(addColumn, alterType)
        XCTAssertLessThan(addColumn, setNotNull)
        XCTAssertLessThan(alterType, createIndex)
        XCTAssertLessThan(setNotNull, createIndex)
        XCTAssertLessThan(createIndex, fkOrders)
        XCTAssertLessThan(createIndex, fkItems)
        XCTAssertLessThan(fkItems, commit)

        // New tables carry PK inline but foreign keys come later.
        let lines = sql.lines()
        let createEnd = lines[createTable...].firstIndex { $0 == ");" }!
        let body = lines[createTable...createEnd].joined(separator: "\n")
        XCTAssertTrue(body.contains("CONSTRAINT order_items_pkey PRIMARY KEY (order_id, product_id)"))
        XCTAssertFalse(body.contains("FOREIGN KEY"))
        // Type change: default dropped first, restored after.
        let dropDefault = sql.lineIndex("ALTER TABLE stage.customers ALTER COLUMN country DROP DEFAULT;")
        let setDefault = sql.lineIndex("ALTER TABLE stage.customers ALTER COLUMN country SET DEFAULT 'FR'::bpchar;")
        XCTAssertLessThan(dropDefault, alterType)
        XCTAssertLessThan(alterType, setDefault)
    }

    func testDestructiveStatementsAreCommentedOutByDefault() {
        let diff = makeDiff()
        let safe = MigrationGenerator.generate(diff)
        XCTAssertTrue(safe.hasDestructiveStatements)
        let sql = safe.sql
        XCTAssertTrue(sql.contains("\n-- ALTER TABLE stage.customers DROP COLUMN legacy_code;"))
        XCTAssertTrue(sql.contains("\n-- DROP INDEX stage.products_name_idx;"))
        XCTAssertTrue(sql.contains("\n-- DROP TABLE stage.old_stuff;"))
        XCTAssertTrue(sql.contains("\n-- DROP TYPE stage.old_enum;"))
        XCTAssertFalse(sql.lines().contains("DROP TABLE stage.old_stuff;"))
        XCTAssertTrue(sql.contains("Destructive statements are commented out"))
        XCTAssertFalse(safe.executableStatements.contains { $0.isDestructive })

        let full = MigrationGenerator.generate(diff, options: MigrationOptions(includeDestructive: true))
        let lines = full.sql.lines()
        XCTAssertTrue(lines.contains("ALTER TABLE stage.customers DROP COLUMN legacy_code;"))
        XCTAssertTrue(lines.contains("DROP INDEX stage.products_name_idx;"))
        XCTAssertTrue(lines.contains("DROP TYPE stage.old_enum;"))
        // Referencing table dropped before the referenced one, types after tables.
        let child = full.sql.lineIndex("DROP TABLE stage.old_child;")
        let parent = full.sql.lineIndex("DROP TABLE stage.old_stuff;")
        let type = full.sql.lineIndex("DROP TYPE stage.old_enum;")
        XCTAssertLessThan(child, parent)
        XCTAssertLessThan(parent, type)
        XCTAssertTrue(full.executableStatements.contains { $0.isDestructive })
    }

    func testTransactionWrappingAndEmptyDiff() {
        let diff = makeDiff()
        let bare = MigrationGenerator.generate(diff, options: MigrationOptions(wrapInTransaction: false, includeComments: false)).sql
        XCTAssertFalse(bare.contains("BEGIN;"))
        XCTAssertFalse(bare.contains("COMMIT;"))
        XCTAssertFalse(bare.contains("-- New tables"))

        let empty = MigrationGenerator.generate(SchemaDiff.compare(source: Fx.shop(), target: Fx.shop(schema: "x")))
        XCTAssertTrue(empty.isEmpty)
        XCTAssertTrue(empty.sql.contains("No differences"))
        XCTAssertFalse(empty.sql.contains("BEGIN;"))
    }

    func testSameSchemaNameKeepsTypesAsIs() {
        // Typical staging → production comparison: both sides are `public`.
        var target = Fx.shop()
        target[1].columns[2] = Fx.col("status", "text", nullable: false, default: "'pending'::text", ordinal: 3)
        let diff = SchemaDiff.compare(source: Fx.shop(), target: target)
        let sql = MigrationGenerator.generate(diff).sql
        XCTAssertTrue(sql.contains("ALTER TABLE public.orders ALTER COLUMN status TYPE order_status USING status::order_status;"), sql)
        XCTAssertTrue(sql.contains("ALTER TABLE public.orders ALTER COLUMN status SET DEFAULT 'pending'::order_status;"))
        XCTAssertFalse(sql.contains("search_path"))
    }

    func testCreatedTableRetargetsEnumsSequencesAndComments() {
        let src = SchemaSnapshot(schema: "public", tables: Fx.shop(), enums: [EnumTypeDef(schema: "public", name: "order_status", values: ["pending"])])
        let dst = SchemaSnapshot(schema: "copy", tables: [])
        let sql = MigrationGenerator.generate(SchemaDiff.compare(source: src, target: dst)).sql
        XCTAssertTrue(sql.contains("CREATE TYPE copy.order_status AS ENUM ('pending');"))
        XCTAssertTrue(sql.contains("  status copy.order_status NOT NULL DEFAULT 'pending'::copy.order_status"), sql)
        XCTAssertTrue(sql.contains("CREATE SEQUENCE IF NOT EXISTS copy.products_id_seq AS integer;"))
        XCTAssertTrue(sql.contains("  id bigint NOT NULL DEFAULT nextval('copy.customers_id_seq'::regclass)"))
        XCTAssertTrue(sql.contains("ALTER SEQUENCE copy.customers_id_seq OWNED BY copy.customers.id;"))
        XCTAssertTrue(sql.contains("COMMENT ON COLUMN copy.customers.email IS 'Login email';"))
        XCTAssertTrue(sql.contains("  CONSTRAINT products_price_check CHECK (price >= 0::numeric)"))
        let seq = sql.lineIndex("CREATE SEQUENCE IF NOT EXISTS copy.customers_id_seq;")
        let table = sql.lineIndex("CREATE TABLE copy.customers (")
        let owned = sql.lineIndex("ALTER SEQUENCE copy.customers_id_seq OWNED BY")
        XCTAssertLessThan(seq, table)
        XCTAssertLessThan(table, owned)
    }

    func testRenamesAndConstraintRecreation() {
        var target = Fx.shop()
        target[1].indexes = target[1].indexes.map { i in
            var i = i
            if i.name == "orders_customer_idx" {
                i.name = "orders_cust"
                i.definition = "CREATE INDEX orders_cust ON public.orders USING btree (customer_id)"
            }
            return i
        }
        target[2].constraints = target[2].constraints.map { c in
            var c = c
            if c.name == "products_price_check" { c.definition = "CHECK (price > 0::numeric)" }
            return c
        }
        let sql = MigrationGenerator.generate(SchemaDiff.compare(source: Fx.shop(), target: target)).sql
        XCTAssertTrue(sql.contains("ALTER INDEX public.orders_cust RENAME TO orders_customer_idx;"), sql)
        let drop = sql.lineIndex("ALTER TABLE public.products DROP CONSTRAINT products_price_check;")
        let add = sql.lineIndex("ALTER TABLE public.products ADD CONSTRAINT products_price_check CHECK (price >= 0::numeric);")
        XCTAssertLessThan(drop, add)
        XCTAssertFalse(sql.contains("-- ALTER TABLE public.products DROP CONSTRAINT"), "recreating a changed constraint is not destructive")
    }

    func testViewsAndIdentity() {
        var srcTables = Fx.shop()
        srcTables[3].columns.append(Fx.col("line_id", "bigint", udt: "int8", nullable: false, identity: true, ordinal: 5))
        var dstTables = Fx.shop()
        dstTables[3].columns.append(Fx.col("line_id", "bigint", udt: "int8", nullable: false, ordinal: 5))
        let src = SchemaSnapshot(schema: "public", tables: srcTables,
                                 views: [ViewDef(schema: "public", name: "stats", kind: .view, definition: " SELECT count(*) AS n\n   FROM orders;"),
                                         ViewDef(schema: "public", name: "mv", kind: .materializedView, definition: " SELECT 1 AS one;")])
        let dst = SchemaSnapshot(schema: "public", tables: dstTables,
                                 views: [ViewDef(schema: "public", name: "stats", kind: .view, definition: " SELECT 1 AS n;"),
                                         ViewDef(schema: "public", name: "gone", kind: .view, definition: " SELECT 2;")])
        let script = MigrationGenerator.generate(SchemaDiff.compare(source: src, target: dst))
        let sql = script.sql
        XCTAssertTrue(sql.contains("ALTER TABLE public.order_items ALTER COLUMN line_id ADD GENERATED BY DEFAULT AS IDENTITY;"), sql)
        let dropStats = sql.lineIndex("DROP VIEW IF EXISTS public.stats;")
        let createStats = sql.lineIndex("CREATE VIEW public.stats AS")
        XCTAssertLessThan(dropStats, createStats)
        XCTAssertTrue(sql.contains("CREATE MATERIALIZED VIEW public.mv AS\nSELECT 1 AS one;"))
        XCTAssertTrue(sql.contains("-- DROP VIEW public.gone;"))
        let phases = script.orderedStatements.map(\.phase)
        XCTAssertEqual(phases, phases.sorted())
    }

    func testSQLiteNotes() {
        var target = Fx.shop(schema: "main")
        target[0].columns[3] = Fx.col("country", "TEXT", ordinal: 4)
        let src = Fx.shop(schema: "main")
        let diff = SchemaDiff.compare(source: src, target: target)
        let sql = MigrationGenerator.generate(diff, dialect: SQLDialect(kind: .sqlite)).sql
        XCTAssertTrue(sql.contains("SQLite cannot alter columns"), sql)
        XCTAssertFalse(sql.contains("ALTER COLUMN"))
    }
}
