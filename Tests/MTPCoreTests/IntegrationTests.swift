import XCTest
@testable import MTPCore

/// Runs against a disposable server: MTP_TEST_PG="host:port:user:password:db".
final class IntegrationTests: XCTestCase {
    func pgClient() throws -> DBClient {
        guard let spec = ProcessInfo.processInfo.environment["MTP_TEST_PG"] else { throw XCTSkip("MTP_TEST_PG not set") }
        let p = spec.split(separator: ":").map(String.init)
        let c = ConnectionConfig(name: "test", driver: .postgres, host: p[0], port: Int(p[1]), user: p[2], database: p[4], sslMode: .disable)
        return DBClient(config: c, secrets: ConnectionSecrets(password: p[3]))
    }

    /// The query editor fetches with a row cap (single-row mode); a small grouped result must come back whole.
    func testRowCapKeepsEveryRowOfSmallResults() async throws {
        let client = try pgClient()
        _ = try await client.connect()
        let r = try await client.query("SELECT status, sum(total) AS revenue FROM orders GROUP BY 1", maxRows: 10_000)
        XCTAssertEqual(r.rows.count, 4)
        XCTAssertFalse(r.isTruncated)
    }

    func testPostgresRoundTrip() async throws {
        let client = try pgClient()
        let info = try await client.connect()
        XCTAssertEqual(info.product, "PostgreSQL")
        XCTAssertEqual(info.currentDatabase, "shop")

        let r = try await client.query("SELECT id, email, metadata, created_at, null::text AS n FROM customers ORDER BY id LIMIT 3")
        XCTAssertEqual(r.rows.count, 3)
        XCTAssertEqual(r.columns.map(\.typeName), ["int8", "text", "jsonb", "timestamptz", "text"])
        XCTAssertNil(r.rows[0][4])
        XCTAssertNotEqual(r.columns[0].tableOID, 0)

        let truncated = try await client.query("SELECT * FROM order_items", maxRows: 100)
        XCTAssertEqual(truncated.rows.count, 100)
        XCTAssertTrue(truncated.isTruncated)
        // Connection still usable after the early stop.
        let after = try await client.query("SELECT 1")
        XCTAssertEqual(after.rows.first?.first, "1")

        let e = try await client.query("SELECT 'paid'::order_status")
        XCTAssertEqual(e.columns[0].kind, .enumeration)

        do {
            _ = try await client.query("SELECT * FROM nope")
            XCTFail("expected error")
        } catch let err as DatabaseError {
            XCTAssertEqual(err.sqlState, "42P01")
            XCTAssertNotNil(err.position)
        }

        let dry = try await client.dryRun("UPDATE products SET stock = stock + 1 WHERE id <= 10")
        XCTAssertEqual(dry.affectedRows, 10)
        let audit = try await client.query("SELECT count(*) FROM audit_log")
        XCTAssertEqual(audit.rows[0][0], "0", "dry run must roll back trigger side effects")
    }

    func testCancel() async throws {
        let client = try pgClient()
        try await client.connect()
        let task = Task { try await client.query("SELECT pg_sleep(5)") }
        try await Task.sleep(nanoseconds: 300_000_000)
        client.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch let err as DatabaseError {
            XCTAssertTrue(err.isCancellation, err.fullMessage)
        }
    }

    func testIntrospection() async throws {
        let client = try pgClient()
        let intro = Introspection.make(client)
        let schemas = try await intro.schemas(includeSystem: false)
        XCTAssertEqual(schemas.first, "public")
        XCTAssertTrue(schemas.contains("analytics"))
        let objects = try await intro.objects(in: "public")
        XCTAssertTrue(objects.contains { $0.name == "orders" && $0.kind == .table })
        XCTAssertTrue(objects.contains { $0.name == "customer_stats" && $0.kind == .view })
        XCTAssertTrue(objects.contains { $0.name == "daily_revenue" && $0.kind == .materializedView })
        XCTAssertTrue(objects.contains { $0.kind == .function && $0.signature == "order_total(p_order bigint)" })
        XCTAssertTrue(objects.contains { $0.kind == .type && $0.name == "order_status" })

        let orders = try await intro.tableDetails(schema: "public", name: "orders")
        XCTAssertEqual(orders.primaryKey, ["id"])
        XCTAssertEqual(orders.columns.first { $0.name == "status" }?.enumValues, ["pending", "paid", "shipped", "cancelled"])
        XCTAssertEqual(orders.columns.first { $0.name == "customer_id" }?.foreignKey?.refTable, "customers")
        XCTAssertTrue(orders.indexes.contains { $0.name == "orders_status_placed_idx" && $0.columns == ["status", "placed_at"] && $0.definition.contains("placed_at DESC") })

        let items = try await intro.tableDetails(schema: "public", name: "order_items")
        XCTAssertEqual(items.primaryKey, ["order_id", "product_id"])
        let products = try await intro.tableDetails(schema: "public", name: "products")
        XCTAssertEqual(products.triggers.first?.name, "products_audit")

        let snap = try await intro.snapshot(schema: "public")
        XCTAssertGreaterThanOrEqual(snap.count, 7)
        let ddl = try await intro.ddl(for: DBObject(schema: "public", name: "orders", kind: .table))
        XCTAssertTrue(ddl.contains("CONSTRAINT orders_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES customers(id) ON DELETE CASCADE"), ddl)

        let cols = try await intro.columnsByTable(schema: "public")
        XCTAssertEqual(cols["customers"]?.first?.name, "id")
    }

    func testEditRoundTrip() async throws {
        let client = try pgClient()
        let intro = Introspection.make(client)
        let details = try await intro.tableDetails(schema: "public", name: "audit_log")
        XCTAssertTrue(details.primaryKey.isEmpty)
        _ = try await client.query("INSERT INTO audit_log(actor, action) VALUES ('t', 'x')")
        let q = TableQuery(schema: "public", table: "audit_log", columns: details.columns, includeRowID: true, dialect: client.dialect)
        let page = try await client.query(q.selectSQL())
        XCTAssertEqual(page.columns.last?.name, TableQuery.rowIDAlias)
        var cs = ChangeSet()
        cs.set(row: 0, column: "action", to: .value("edited"))
        let builder = ChangeSetBuilder(schema: "public", table: "audit_log", columns: details.columns, primaryKey: [], dialect: client.dialect)
        let st = try builder.statements(for: cs, rows: page.rows, resultColumns: page.columns.map(\.name))
        let res = try await client.transaction(st)
        XCTAssertEqual(res.first?.affectedRows, 1)
        _ = try await client.query("DELETE FROM audit_log")
    }

    func testSQLite() async throws {
        let path = NSTemporaryDirectory() + "mtp-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let c = ConnectionConfig(name: "lite", driver: .sqlite, filePath: path)
        let client = DBClient(config: c, secrets: ConnectionSecrets())
        _ = try await client.query("""
            CREATE TABLE a (id INTEGER PRIMARY KEY, name TEXT NOT NULL DEFAULT 'x', blob BLOB);
            CREATE TABLE b (id INTEGER PRIMARY KEY, a_id INTEGER REFERENCES a(id) ON DELETE CASCADE, v REAL);
            CREATE INDEX b_a ON b(a_id);
            INSERT INTO a(name, blob) VALUES ('one', x'00ff'), ('two', NULL);
            """)
        let r = try await client.query("SELECT * FROM a ORDER BY id")
        XCTAssertEqual(r.rows.count, 2)
        XCTAssertEqual(r.rows[0][2], "x'00ff'")
        let intro = Introspection.make(client)
        let b = try await intro.tableDetails(schema: "main", name: "b")
        XCTAssertEqual(b.primaryKey, ["id"])
        XCTAssertEqual(b.foreignKeys.first?.refTable, "a")
        XCTAssertEqual(b.indexes.first?.columns, ["a_id"])
        var q = TableQuery(schema: "main", table: "a", columns: [], dialect: client.dialect)
        q.filters = [FilterRule(column: "name", op: .startsWith, value: "o")]
        let f = try await client.query(q.selectSQL())
        XCTAssertEqual(f.rows.count, 1)
    }
}
