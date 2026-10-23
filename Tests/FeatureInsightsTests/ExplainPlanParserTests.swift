import XCTest
import MTPCore
@testable import FeatureInsights

final class ExplainPlanParserTests: XCTestCase {
    func testNestedLoopAnalyze() throws {
        let plan = try ExplainPlanParser.parse(json: PlanFixtures.nestedAnalyze)
        XCTAssertTrue(plan.isAnalyze)
        XCTAssertEqual(plan.planningTime, 0.764)
        XCTAssertEqual(plan.executionTime, 2.498)
        XCTAssertEqual(plan.totalCost, 251.01)
        XCTAssertEqual(plan.planningSharedHit, 298)
        XCTAssertEqual(plan.nodes.map(\.nodeType), ["Limit", "Sort", "Nested Loop", "Seq Scan", "Index Scan"])
        XCTAssertEqual(plan.nodes.map(\.id), [0, 1, 2, 3, 4])
        XCTAssertEqual(plan.nodes.map(\.depth), [0, 1, 2, 3, 3])

        let sort = try XCTUnwrap(plan.node(id: 1))
        XCTAssertEqual(sort.conditions.first { $0.label == "Sort Key" }?.value, "o.total DESC")
        XCTAssertEqual(sort.conditions.first { $0.label == "Sort Method" }?.value, "top-N heapsort (27 kB Memory)")

        let seq = try XCTUnwrap(plan.node(id: 3))
        XCTAssertEqual(seq.targetDescription, "on public.customers c")
        XCTAssertEqual(seq.conditions.first { $0.label == "Filter" }?.value, "((c.metadata ->> 'plan'::text) = 'free'::text)")
        XCTAssertNotNil(seq.conditions.first { $0.label == "Rows Removed by Filter" })
        XCTAssertEqual(seq.output.first, "c.id")
        // 12 estimated, 833 actual.
        XCTAssertEqual(try XCTUnwrap(seq.misestimateFactor), 833.0 / 12.0, accuracy: 0.001)
        XCTAssertTrue(seq.isUnderestimated)

        let index = try XCTUnwrap(plan.node(id: 4))
        XCTAssertEqual(index.indexName, "orders_customer_idx")
        XCTAssertEqual(index.actualLoops, 833)
        XCTAssertNotNil(index.conditions.first { $0.label == "Index Cond" })
        // Per-loop time × loops.
        XCTAssertEqual(try XCTUnwrap(index.inclusiveTime), 0.002 * 833, accuracy: 1e-9)
        XCTAssertNil(index.misestimateFactor.flatMap { $0 >= 10 ? $0 : nil })

        let loop = try XCTUnwrap(plan.node(id: 2))
        XCTAssertEqual(loop.displayName, "Nested Loop")
        XCTAssertEqual(try XCTUnwrap(loop.exclusiveTime), 2.106 - 0.346 - 0.002 * 833, accuracy: 1e-9)
        XCTAssertEqual(loop.sharedHitBlocks, 4371)
        XCTAssertEqual(loop.sharedReadBlocks, 0)

        // The inner index scan (833 loops) dominates.
        XCTAssertEqual(plan.mostExpensiveNodeID, 4)
        let shares = plan.nodes.map { plan.share(of: $0) }
        XCTAssertTrue(shares.allSatisfy { $0 >= 0 && $0 <= 1 })
        XCTAssertLessThanOrEqual(shares.reduce(0, +), 1.0001)
        // Exclusive times add up to the root's inclusive time.
        let sum = plan.nodes.compactMap(\.exclusiveTime).reduce(0, +)
        XCTAssertEqual(sum, try XCTUnwrap(plan.root.inclusiveTime), accuracy: 1e-9)
    }

    func testParallelPlanDividesWorkerTime() throws {
        let plan = try ExplainPlanParser.parse(json: PlanFixtures.parallelAnalyze)
        XCTAssertEqual(plan.nodes.map(\.displayName),
                       ["Finalize Aggregate", "Gather", "Partial Aggregate", "Parallel Seq Scan"])
        let gather = try XCTUnwrap(plan.node(id: 1))
        XCTAssertEqual(gather.workersLaunched, 2)
        // 3 loops (leader + 2 workers) run concurrently: wall-clock is total time × loops / 3.
        let partial = try XCTUnwrap(plan.node(id: 2))
        XCTAssertEqual(try XCTUnwrap(partial.inclusiveTime), 0.505, accuracy: 1e-9)
        XCTAssertGreaterThan(try XCTUnwrap(gather.exclusiveTime), 3)
        XCTAssertEqual(plan.mostExpensiveNodeID, 1)
    }

    func testCostsOnlyPlan() throws {
        let plan = try ExplainPlanParser.parse(json: PlanFixtures.selectCosts)
        XCTAssertFalse(plan.isAnalyze)
        XCTAssertNil(plan.executionTime)
        XCTAssertNil(plan.planningTime)
        XCTAssertEqual(plan.nodes.map(\.displayName), ["HashAggregate", "Hash Join", "Seq Scan", "Hash", "Seq Scan"])
        XCTAssertTrue(plan.nodes.allSatisfy { $0.actualRows == nil && $0.exclusiveTime == nil && $0.misestimateFactor == nil })
        let join = try XCTUnwrap(plan.node(id: 1))
        XCTAssertNotNil(join.conditions.first { $0.label == "Hash Cond" })
        XCTAssertEqual(join.exclusiveCost, 470.46 - 392.40 - 10.00, accuracy: 1e-9)
        // Without ANALYZE the bar uses exclusive cost.
        XCTAssertEqual(plan.share(of: join), join.exclusiveCost / 583.93, accuracy: 1e-9)
        // Seq Scan on order_items: 392.40 of 583.93.
        XCTAssertEqual(plan.mostExpensiveNodeID, 2)
    }

    func testUpdateWithTrigger() throws {
        let plan = try ExplainPlanParser.parse(json: PlanFixtures.updateAnalyze)
        XCTAssertEqual(plan.root.displayName, "Update")
        XCTAssertEqual(plan.root.targetDescription, "on public.products")
        XCTAssertEqual(plan.triggers.count, 1)
        XCTAssertEqual(plan.triggers.first?.name, "products_audit")
        XCTAssertEqual(plan.triggers.first?.relation, "products")
        XCTAssertEqual(plan.triggers.first?.calls, 5)
        XCTAssertEqual(plan.node(id: 1)?.indexName, "products_pkey")
        XCTAssertEqual(plan.executionTime, 30.337)
    }

    func testAcceptsObjectAndRejectsGarbage() throws {
        let single = #"{"Plan": {"Node Type": "Result", "Startup Cost": 0, "Total Cost": 0.01, "Plan Rows": 1, "Plan Width": 4}}"#
        let plan = try ExplainPlanParser.parse(json: single)
        XCTAssertEqual(plan.root.nodeType, "Result")
        XCTAssertEqual(plan.mostExpensiveNodeID, 0)

        XCTAssertThrowsError(try ExplainPlanParser.parse(json: "QUERY PLAN\nSeq Scan on t")) { error in
            guard case ExplainPlanError.invalidJSON = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try ExplainPlanParser.parse(json: "[{\"Planning Time\": 1}]")) { error in
            XCTAssertEqual(error as? ExplainPlanError, .missingPlan)
        }
        // Wrong types never crash.
        let odd = #"[{"Plan": {"Node Type": 5, "Total Cost": "12.5", "Actual Loops": true, "Plans": "x"}}]"#
        let p = try ExplainPlanParser.parse(json: odd)
        XCTAssertEqual(p.root.nodeType, "5")
        XCTAssertEqual(p.root.totalCost, 12.5)
        XCTAssertNil(p.root.actualLoops)
        XCTAssertTrue(p.root.children.isEmpty)
    }

    func testDisplayNames() throws {
        func name(_ fields: String) throws -> String {
            try ExplainPlanParser.parse(json: "{\"Plan\": {\(fields)}}").root.displayName
        }
        XCTAssertEqual(try name(#""Node Type": "Hash Join", "Join Type": "Left""#), "Hash Left Join")
        XCTAssertEqual(try name(#""Node Type": "Nested Loop", "Join Type": "Anti""#), "Nested Loop Anti Join")
        XCTAssertEqual(try name(#""Node Type": "Aggregate", "Strategy": "Sorted", "Partial Mode": "Simple""#), "GroupAggregate")
        XCTAssertEqual(try name(#""Node Type": "Index Scan", "Scan Direction": "Backward""#), "Index Scan Backward")
        XCTAssertEqual(try name(#""Node Type": "ModifyTable", "Operation": "Delete""#), "Delete")
    }
}

final class ExplainSQLTests: XCTestCase {
    func testInnerStatement() {
        XCTAssertEqual(ExplainSQL.innerStatement("SELECT 1;"), "SELECT 1")
        XCTAssertEqual(ExplainSQL.innerStatement("explain analyze select * from t;"), "select * from t")
        XCTAssertEqual(ExplainSQL.innerStatement("EXPLAIN (ANALYZE, FORMAT JSON) SELECT (1)"), "SELECT (1)")
        XCTAssertEqual(ExplainSQL.innerStatement("EXPLAIN QUERY PLAN SELECT * FROM a"), "SELECT * FROM a")
        XCTAssertEqual(ExplainSQL.innerStatement("  SELECT 1; SELECT 2;"), "SELECT 1")
        XCTAssertEqual(ExplainSQL.innerStatement("EXPLAIN"), "")
    }

    func testPostgresOptionsByVersion() {
        XCTAssertEqual(ExplainSQL.postgres("SELECT 1", format: .json, analyze: true, serverVersion: 140005),
                       "EXPLAIN (FORMAT JSON, VERBOSE, BUFFERS, ANALYZE, SETTINGS) SELECT 1")
        XCTAssertEqual(ExplainSQL.postgres("SELECT 1", format: .text, analyze: false, serverVersion: 110000),
                       "EXPLAIN (FORMAT TEXT, VERBOSE) SELECT 1")
    }

    func testExecutionMode() {
        XCTAssertEqual(ExplainExecution.for(analyze: false, isWrite: true), .direct)
        XCTAssertEqual(ExplainExecution.for(analyze: true, isWrite: false), .readOnlyRollback)
        XCTAssertEqual(ExplainExecution.for(analyze: true, isWrite: true), .rollback)
    }

    func testSQLiteTree() {
        let nodes = SQLiteQueryPlan.build([
            (id: 2, parent: 0, detail: "SCAN a"),
            (id: 5, parent: 0, detail: "SEARCH b USING INDEX b_a (a_id=?)"),
            (id: 9, parent: 0, detail: "USE TEMP B-TREE FOR ORDER BY"),
            (id: 12, parent: 5, detail: "CORRELATED SCALAR SUBQUERY 1"),
            (id: 15, parent: 12, detail: "SCAN c"),
            (id: 20, parent: 99, detail: "orphan"),
        ])
        XCTAssertEqual(nodes.map(\.id), [2, 5, 9, 20])
        let flat = nodes.flatMap(\.flattened)
        XCTAssertEqual(flat.map(\.id), [2, 5, 12, 15, 9, 20])
        XCTAssertEqual(flat.map(\.depth), [0, 0, 1, 2, 0, 0])
        XCTAssertTrue(flat[0].isFullScan)
        XCTAssertFalse(flat[1].isFullScan)
        XCTAssertTrue(flat[4].usesTempBTree)
    }
}

final class InsightsFixTests: XCTestCase {
    func testFixSQLQuotesIdentifiers() {
        XCTAssertTrue(InsightsFix.dropIndex(schema: "public", name: "Orders Idx").contains("DROP INDEX CONCURRENTLY IF EXISTS public.\"Orders Idx\";"))
        XCTAssertEqual(InsightsFix.vacuumAnalyze(schema: "analytics", table: "events"), "VACUUM (ANALYZE, VERBOSE) analytics.events;")
        XCTAssertEqual(InsightsFix.cancelBackend(pid: 42), "SELECT pg_cancel_backend(42);")
        let widen = InsightsFix.widenSequence(schema: "public", sequence: "orders_id_seq", table: "orders", tableSchema: "public",
                                              column: "id", columnType: "integer")
        XCTAssertTrue(widen.contains("ALTER TABLE public.orders ALTER COLUMN id TYPE bigint;"))
        XCTAssertTrue(widen.contains("ALTER SEQUENCE public.orders_id_seq AS bigint"))
    }

    func testFormatting() {
        XCTAssertEqual(InsightsFormat.percent(0.5), "50.0%")
        XCTAssertEqual(InsightsFormat.percent(nil), "—")
        XCTAssertFalse(InsightsFormat.duration(3725).isEmpty)
        XCTAssertEqual(InsightsFormat.oneLine("a\n   b\tc"), "a b c")
    }

    func testProcessRowParsingAndFilter() {
        let cols = ["pid", "usename", "application_name", "state", "query_seconds", "state_seconds", "is_self", "blocked_by", "backend_type", "query"]
        let map = Dictionary(uniqueKeysWithValues: cols.enumerated().map { ($1, $0) })
        let row = ResultRow(values: ["123", "app_user", "rails", "active", "12.5", "3", "f", "7, 9", "client backend", "SELECT *\n  FROM orders"],
                            columns: map)
        let p = PGProcess(row: row)
        XCTAssertEqual(p.pid, 123)
        XCTAssertEqual(p.duration, 12.5)
        XCTAssertEqual(p.blockedBy, [7, 9])
        XCTAssertFalse(p.isSystem)
        XCTAssertEqual(p.queryPreview, "SELECT * FROM orders")
        XCTAssertTrue(p.matches("ORDERS"))
        XCTAssertTrue(p.matches("123"))
        XCTAssertFalse(p.matches("nothing"))
        // Garbage values do not crash.
        let bad = PGProcess(row: ResultRow(values: ["x", nil], columns: ["pid": 0, "usename": 1, "missing": 5]))
        XCTAssertEqual(bad.pid, 0)
        XCTAssertEqual(bad.duration, 0)
    }
}
