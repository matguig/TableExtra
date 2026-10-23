import MTPCore
import XCTest
@testable import FeatureSchemaTools

/// Diffs `public` of the test database against a scratch schema created (and dropped) by the test.
final class LiveDiffTests: XCTestCase {
    var client: DBClient!
    var scratch = ""

    override func setUp() async throws {
        client = try TestDB.client()
        _ = try await client.connect()
        scratch = "mtp_diff_" + UUID().uuidString.prefix(8).lowercased()
        let s = scratch
        _ = try await client.query("""
            CREATE SCHEMA \(s);
            CREATE TYPE \(s).order_status AS ENUM ('pending', 'paid', 'shipped');
            CREATE TYPE \(s).old_enum AS ENUM ('x');
            CREATE TABLE \(s).customers (
              id bigserial PRIMARY KEY,
              email text NOT NULL UNIQUE,
              full_name text,
              country text DEFAULT 'FR',
              created_at timestamptz NOT NULL DEFAULT now(),
              legacy_code text
            );
            CREATE TABLE \(s).products (
              id serial PRIMARY KEY,
              sku text NOT NULL UNIQUE,
              name text NOT NULL,
              price numeric(10,2) NOT NULL,
              stock integer NOT NULL DEFAULT 0,
              tags text[] DEFAULT '{}',
              is_active boolean NOT NULL DEFAULT true
            );
            CREATE INDEX products_name_idx ON \(s).products (name);
            CREATE TABLE \(s).orders (
              id bigserial PRIMARY KEY,
              customer_id bigint NOT NULL,
              status \(s).order_status NOT NULL DEFAULT 'pending',
              total numeric(10,2) NOT NULL DEFAULT 0,
              placed_at timestamptz NOT NULL DEFAULT now(),
              shipped_on date
            );
            CREATE INDEX orders_customer_idx ON \(s).orders (customer_id);
            CREATE TABLE \(s).old_stuff (id integer PRIMARY KEY);
            CREATE TABLE \(s).old_child (stuff_id integer REFERENCES \(s).old_stuff(id));
            """)
    }

    override func tearDown() async throws {
        if let client, !scratch.isEmpty {
            _ = try? await client.query("DROP SCHEMA IF EXISTS \(scratch) CASCADE")
            client.close()
        }
    }

    func snapshots() async throws -> (SchemaSnapshot, SchemaSnapshot) {
        let i = Introspection.make(client)
        let src = try await SchemaSnapshotLoader.load(client: client, introspector: i, schema: "public")
        let dst = try await SchemaSnapshotLoader.load(client: client, introspector: i, schema: scratch)
        return (src, dst)
    }

    func testDiffPublicAgainstScratchSchemaAndApplyMigration() async throws {
        let (src, dst) = try await snapshots()
        let diff = SchemaDiff.compare(source: src, target: dst)

        func change(_ name: String) -> DiffChange? { diff.table(name)?.change }
        XCTAssertEqual(change("order_items"), .added)
        XCTAssertEqual(change("audit_log"), .added)
        XCTAssertEqual(change("kysely_migration"), .added)
        XCTAssertEqual(change("old_stuff"), .removed)
        XCTAssertEqual(change("old_child"), .removed)
        XCTAssertEqual(change("customers"), .changed)
        XCTAssertEqual(change("orders"), .changed)
        XCTAssertEqual(change("products"), .changed)

        let customers = try XCTUnwrap(diff.table("customers"))
        let cols = Dictionary(uniqueKeysWithValues: customers.columns.map { ($0.name, $0) })
        XCTAssertEqual(cols["metadata"]?.change, .added)
        XCTAssertEqual(cols["legacy_code"]?.change, .removed)
        XCTAssertEqual(cols["country"]?.typeChanged, true)
        XCTAssertEqual(cols["full_name"]?.nullabilityChanged, true)
        XCTAssertNil(cols["id"], "serial defaults must compare equal across schemas")

        let orders = try XCTUnwrap(diff.table("orders"))
        XCTAssertEqual(orders.columns.first { $0.name == "total" }?.typeChanged, true)
        XCTAssertTrue(orders.indexes.contains { $0.name == "orders_status_placed_idx" && $0.change == .added })
        XCTAssertFalse(orders.indexes.contains { $0.name == "orders_customer_idx" }, "same index in another schema is unchanged")
        XCTAssertTrue(orders.constraints.contains { $0.name == "orders_customer_id_fkey" && $0.change == .added })

        let products = try XCTUnwrap(diff.table("products"))
        XCTAssertTrue(products.indexes.contains { $0.name == "products_name_idx" && $0.change == .removed })
        XCTAssertTrue(products.constraints.contains { $0.name == "products_price_check" && $0.change == .added })

        XCTAssertTrue(diff.enums.contains { $0.name == "order_status" && $0.change == .changed })
        XCTAssertTrue(diff.enums.contains { $0.name == "old_enum" && $0.change == .removed })
        XCTAssertTrue(diff.views.contains { $0.name == "customer_stats" && $0.change == .added })
        XCTAssertTrue(diff.views.contains { $0.name == "daily_revenue" && $0.change == .added })

        // Safe script: destructive statements are commented out.
        let safe = MigrationGenerator.generate(diff)
        XCTAssertTrue(safe.sql.contains("-- DROP TABLE \(scratch).old_child;"), safe.sql)
        XCTAssertTrue(safe.sql.contains("ALTER TYPE \(scratch).order_status ADD VALUE IF NOT EXISTS 'cancelled' AFTER 'shipped';"))

        // Running the full script on the scratch schema must leave no difference.
        let full = MigrationGenerator.generate(diff, options: MigrationOptions(includeDestructive: true))
        do {
            _ = try await client.query(full.sql)
        } catch {
            XCTFail("migration failed: \(error)\n\(full.sql)")
            return
        }
        let (src2, dst2) = try await snapshots()
        let after = SchemaDiff.compare(source: src2, target: dst2)
        let leftover = after.tables.map { t in
            "\(t.name) \(t.change): cols \(t.columns.map { "\($0.name) \($0.summary)" }) idx \(t.indexes.map(\.name)) cons \(t.constraints.map(\.name))"
        } + after.enums.map { "enum \($0.name) \($0.change)" } + after.views.map { "view \($0.name) \($0.change)" }
        XCTAssertTrue(after.isEmpty, leftover.joined(separator: "\n") + "\n" + MigrationGenerator.generate(after).sql)
    }

    func testIdenticalSchemaHasNoDifferences() async throws {
        let (src, _) = try await snapshots()
        let diff = SchemaDiff.compare(source: src, target: src)
        XCTAssertTrue(diff.isEmpty)
        XCTAssertTrue(MigrationGenerator.generate(diff).isEmpty)
    }
}
