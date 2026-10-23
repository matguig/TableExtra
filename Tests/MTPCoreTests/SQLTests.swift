import XCTest
@testable import MTPCore

final class SQLTests: XCTestCase {
    func testSplitter() {
        let sql = "select 1; -- c\nselect 'a;b'; create function f() returns int as $$ select 1; $$ language sql;\n\nselect 2"
        let parts = StatementSplitter.split(sql).map(\.text)
        XCTAssertEqual(parts.count, 4)
        XCTAssertEqual(parts[1], "-- c\nselect 'a;b'")
        XCTAssertTrue(parts[2].hasPrefix("create function"))
        XCTAssertEqual(parts[3], "select 2")
    }

    func testSQLiteTriggerBody() {
        let sql = "CREATE TRIGGER t AFTER INSERT ON a BEGIN UPDATE b SET x = 1; UPDATE c SET y = CASE WHEN 1 THEN 2 END; END; SELECT 1"
        XCTAssertEqual(StatementSplitter.split(sql).count, 2)
    }

    func testStatementAtCaret() {
        let sql = "select 1;\nselect 2;\n\n\nselect 3"
        XCTAssertEqual(StatementSplitter.statement(at: 3, in: sql)?.text, "select 1")
        XCTAssertEqual(StatementSplitter.statement(at: 19, in: sql)?.text, "select 2")
        XCTAssertEqual(StatementSplitter.statement(at: (sql as NSString).length, in: sql)?.text, "select 3")
    }

    func testClassifier() {
        XCTAssertEqual(QueryClassifier.analyze("SELECT * FROM a").kind, .read)
        XCTAssertEqual(QueryClassifier.analyze("with x as (delete from a returning *) select * from x").kind, .write)
        let d = QueryClassifier.analyze("DELETE FROM \"public\".\"kysely_migration\"")
        XCTAssertTrue(d.isUnbounded)
        XCTAssertEqual(d.targetTable, "\"public\".\"kysely_migration\"")
        XCTAssertFalse(QueryClassifier.analyze("delete from a where id = 1").isUnbounded)
        XCTAssertFalse(QueryClassifier.analyze("update a set x = (select 1 where true)").kind == .read)
        XCTAssertTrue(QueryClassifier.analyze("update a set x = (select 1 where true)").isUnbounded)
        XCTAssertEqual(QueryClassifier.analyze("drop table a").kind, .ddl)
        XCTAssertTrue(QueryClassifier.analyze("explain analyze delete from a").kind == .write)
        XCTAssertTrue(QueryClassifier.isReadOnlyScript("select 1; show search_path"))
    }

    func testFilters() {
        let cols = [ColumnDef(name: "id", dataType: "bigint", udtName: "int8"), ColumnDef(name: "email", dataType: "text", udtName: "text")]
        var q = TableQuery(schema: "public", table: "customers", columns: cols, dialect: SQLDialect(kind: .postgres))
        q.filters = [FilterRule(column: "email", op: .contains, value: "50%"), FilterRule(column: "id", op: .isIn, value: "1, 2")]
        q.sort = [SortKey(column: "id", ascending: false)]
        let s = q.selectSQL()
        XCTAssertEqual(s.sql, "SELECT \"id\", \"email\" FROM \"public\".\"customers\" WHERE \"email\" LIKE $1 AND \"id\" IN ($2, $3) ORDER BY \"id\" DESC LIMIT 300 OFFSET 0")
        XCTAssertEqual(s.params, ["%50\\%%", "1", "2"])
    }

    func testChangeSet() throws {
        let cols = [ColumnDef(name: "id", dataType: "bigint", isPrimaryKey: true), ColumnDef(name: "name", dataType: "text")]
        let b = ChangeSetBuilder(schema: "public", table: "t", columns: cols, primaryKey: ["id"], dialect: SQLDialect(kind: .postgres))
        var cs = ChangeSet()
        cs.set(row: 0, column: "name", to: .value("O'Neil"))
        cs.inserts = [["name": .value("x"), "id": .default]]
        cs.deletes = [1]
        let st = try b.statements(for: cs, rows: [["1", "a"], ["2", "b"]], resultColumns: ["id", "name"])
        XCTAssertEqual(st.map(\.sql), [
            "UPDATE \"public\".\"t\" SET \"name\" = $1 WHERE \"id\" = $2",
            "INSERT INTO \"public\".\"t\" (\"name\") VALUES ($1)",
            "DELETE FROM \"public\".\"t\" WHERE \"id\" = $1",
        ])
        XCTAssertTrue(b.preview(st).contains("'O''Neil'"))
    }

    func testURL() {
        let (c, s) = ConnectionURL.parse("postgresql://bob:p%40ss@db.example.rds.amazonaws.com:6543/shop?sslmode=verify-full")!
        XCTAssertEqual(c.host, "db.example.rds.amazonaws.com")
        XCTAssertEqual(c.port, 6543)
        XCTAssertEqual(c.user, "bob")
        XCTAssertEqual(s.password, "p@ss")
        XCTAssertEqual(c.database, "shop")
        XCTAssertEqual(c.sslMode, .verifyFull)
    }

    func testFormatter() {
        let f = SQLFormatter.format("select a, b from t join u on u.id = t.uid where a = 1 and b in (select x from y) order by a")
        XCTAssertTrue(f.contains("\nFROM t"), f)
        XCTAssertTrue(f.contains("\nWHERE a = 1\n  AND b IN ("), f)
    }
}

final class ObjectGroupingTests: XCTestCase {
    private func t(_ name: String) -> DBObject { DBObject(schema: "public", name: name, kind: .table) }

    func testSeriesFoldsDateSuffixes() {
        let objs = ["amazon_product_info", "amazon_webhook_request_20260725", "amazon_webhook_request_20260726",
                    "amazon_webhook_request_20260727", "orders"].map(t)
        let nodes = ObjectGrouping.nodes(for: objs, prefixFolders: false)
        XCTAssertEqual(nodes.count, 3)
        guard case .group(_, let title, .series, let children) = nodes[1] else { return XCTFail("\(nodes)") }
        XCTAssertEqual(title, "amazon_webhook_request_*")
        XCTAssertEqual(children.count, 3)
        guard case .object(_, let display) = children[0] else { return XCTFail() }
        XCTAssertEqual(display, "2026-07-25")
    }

    func testTwoSiblingsAreNotASeries() {
        let nodes = ObjectGrouping.nodes(for: ["logs_2025", "logs_2026", "users"].map(t), prefixFolders: false)
        XCTAssertEqual(nodes.count, 3)
    }

    func testPrefixFoldersStripPrefixAndKeepLooseItems() {
        var names = (1...20).map { "misc\($0)" }
        names += ["ai_item_candidate_price", "ai_item_level_history", "ai_report_generations",
                  "amazon_product_info", "amazon_webhook_request_20260725", "amazon_webhook_request_20260726", "amazon_webhook_request_20260727"]
        let nodes = ObjectGrouping.nodes(for: names.sorted().map(t), prefixFolders: true)
        let ai = nodes.first { if case .group(_, "ai", .prefix, _) = $0 { return true }; return false }
        guard case .group(let id, _, _, let children)? = ai else { return XCTFail("\(nodes)") }
        XCTAssertEqual(id, "prefix:public.table.ai")
        XCTAssertEqual(children.count, 3)
        guard case .object(_, let display) = children[0] else { return XCTFail() }
        XCTAssertEqual(display, "item_candidate_price")
        let amazon = nodes.first { if case .group(_, "amazon", .prefix, _) = $0 { return true }; return false }
        XCTAssertEqual(amazon?.objectCount, 4)
        guard case .group(_, _, _, let amazonChildren)? = amazon, case .group(_, let seriesTitle, .series, _) = amazonChildren[1] else { return XCTFail() }
        XCTAssertEqual(seriesTitle, "webhook_request_*")
        XCTAssertTrue(nodes.contains { if case .object(let o, _) = $0 { return o.name == "misc1" }; return false })
    }

    func testSmallListsStayFlat() {
        let nodes = ObjectGrouping.nodes(for: ["ai_a", "ai_b", "ai_c", "users"].map(t), prefixFolders: true)
        XCTAssertEqual(nodes.count, 4)
    }
}

final class ChartDataTests: XCTestCase {
    private func result(_ cols: [(String, String)], _ rows: [[String?]]) -> QueryResult {
        QueryResult(columns: cols.map { ResultColumn(name: $0.0, typeName: $0.1) }, rows: rows)
    }

    func testSuggestPicksTimeAndMeasures() {
        let r = result([("id", "int8"), ("day", "date"), ("revenue", "numeric"), ("orders", "int8")],
                       [["1", "2026-10-01", "10.5", "3"]])
        let c = ChartData.suggest(for: r)
        XCTAssertEqual(c.x, "day")
        XCTAssertEqual(c.ys, ["revenue"])
        XCTAssertEqual(c.kind, .line)
    }

    func testSuggestFallsBackToCount() {
        let c = ChartData.suggest(for: result([("status", "text")], [["paid"]]))
        XCTAssertEqual(c.x, "status")
        XCTAssertEqual(c.aggregate, .count)
        XCTAssertTrue(c.isComplete)
    }

    func testAggregateSumBySeries() {
        let r = result([("status", "text"), ("country", "text"), ("total", "numeric")],
                       [["paid", "FR", "10"], ["paid", "FR", "5"], ["paid", "US", "1"], ["open", "FR", nil]])
        let d = ChartData.build(r, config: ChartConfig(kind: .bar, x: "status", ys: ["total"], series: "country", aggregate: .sum))
        XCTAssertEqual(d.series, ["FR", "US"])
        XCTAssertEqual(d.points.first { $0.x == ChartX.text("paid") && $0.series == "FR" }?.value, 15)
        XCTAssertEqual(d.skippedRows, 1)
    }

    func testDatesFromPostgresTimestamps() {
        let r = result([("placed_at", "timestamptz"), ("total", "numeric")],
                       [["2026-10-23 08:51:35.240849+02", "54"], ["2026-10-22 08:51:35.2+02", "10"]])
        let d = ChartData.build(r, config: ChartConfig(kind: .line, x: "placed_at", ys: ["total"]))
        XCTAssertEqual(d.xKind, .date)
        XCTAssertEqual(d.points.count, 2)
        XCTAssertEqual(d.points.first?.value, 10, "sorted by date")
    }

    func testPieFoldsSmallSlices() {
        let rows: [[String?]] = (1...20).map { ["c\($0)", String($0)] }
        let d = ChartData.build(result([("cat", "text"), ("n", "int4")], rows), config: ChartConfig(kind: .pie, x: "cat", ys: ["n"]))
        XCTAssertEqual(d.points.count, ChartData.maxSlices)
        XCTAssertEqual(d.points.last?.x, ChartX.text("Other"))
        XCTAssertEqual(d.points.first?.x, ChartX.text("c20"))
    }
}

final class RDSEndpointTests: XCTestCase {
    func testInstanceClusterAndProxyHosts() {
        let i = RDSEndpoint.parse("mydb.abc123xyz.eu-west-1.rds.amazonaws.com")
        XCTAssertEqual(i, RDSEndpoint(identifier: "mydb", region: "eu-west-1", kind: .instance))
        let c = RDSEndpoint.parse("production-acme-main-db.cluster-abc123xyz.us-east-1.rds.amazonaws.com")
        XCTAssertEqual(c?.kind, .cluster)
        XCTAssertEqual(c?.identifier, "production-acme-main-db")
        XCTAssertEqual(RDSEndpoint.parse("app.cluster-ro-abc.us-east-1.rds.amazonaws.com")?.kind, .cluster)
        XCTAssertEqual(RDSEndpoint.parse("p.proxy-abc.us-east-1.rds.amazonaws.com")?.kind, .proxy)
        XCTAssertNil(RDSEndpoint.parse("localhost"))
        XCTAssertNil(RDSEndpoint.parse("db.example.com"))
    }

    func testEffectiveAWSFromHostAndOverrides() {
        var c = ConnectionConfig(name: "x", host: "app.cluster-abc.us-east-1.rds.amazonaws.com")
        XCTAssertEqual(c.effectiveAWS?.identifier, "app")
        XCTAssertEqual(c.effectiveAWS?.isCluster, true)
        c.aws = AWSSettings(profile: "prod")
        XCTAssertEqual(c.effectiveAWS?.profile, "prod")
        XCTAssertEqual(c.effectiveAWS?.region, "us-east-1")
        c.aws?.isEnabled = false
        XCTAssertNil(c.effectiveAWS)
    }
}
