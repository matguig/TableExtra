import XCTest
import MTPCore
import MTPUIKit
@testable import FeatureInsights

/// Runs against the disposable test server (MTP_TEST_PG); skipped otherwise. Leaves no permanent changes.
final class InsightsIntegrationTests: XCTestCase {
    /// Every statement of the dashboard runs as-is.
    func testEverySectionSQLRuns() async throws {
        let client = try TestDB.pgClient()
        defer { client.close() }
        let sqls: [(String, String)] = [
            ("session", InsightsSQL.session), ("processListSession", InsightsSQL.processListSession),
            ("server", InsightsSQL.server), ("databaseSize", InsightsSQL.databaseSize),
            ("databaseStats", InsightsSQL.databaseStats), ("tableCache", InsightsSQL.tableCache),
            ("tables", InsightsSQL.tables(limit: 50)), ("unusedIndexes", InsightsSQL.unusedIndexes),
            ("duplicateIndexes", InsightsSQL.duplicateIndexes), ("largestIndexes", InsightsSQL.largestIndexes),
            ("statementsStatus", InsightsSQL.statementsStatus), ("blocking", InsightsSQL.blocking),
            ("longTransactions", InsightsSQL.longTransactions(minSeconds: 60)), ("activity", InsightsSQL.activity),
            ("vacuum", InsightsSQL.vacuum), ("xidAge", InsightsSQL.xidAge),
        ]
        for (name, sql) in sqls {
            do { _ = try await client.query(sql) } catch { XCTFail("\(name): \(error.insightsMessage)") }
        }
        do { _ = try await client.query(InsightsSQL.sequences, ["0.75"]) } catch { XCTFail("sequences: \(error.insightsMessage)") }
        do { _ = try await client.query(InsightsSQL.statementsColumns, ["public"]) } catch { XCTFail("statementsColumns: \(error.insightsMessage)") }
    }

    func testSectionsMapResults() async throws {
        let client = try TestDB.pgClient()
        defer { client.close() }
        let insights = PostgresInsights(client: client)
        try await insights.prepareSession()

        let overview = try await insights.overview()
        XCTAssertTrue(overview.errors.isEmpty, "\(overview.errors)")
        XCTAssertTrue(overview.serverVersion?.hasPrefix("14") ?? false, "\(String(describing: overview.serverVersion))")
        XCTAssertGreaterThan(overview.uptimeSeconds ?? 0, 0)
        XCTAssertGreaterThan(overview.databaseBytes ?? 0, 0)
        XCTAssertGreaterThan(overview.maxConnections ?? 0, 0)
        XCTAssertGreaterThanOrEqual(overview.connections ?? 0, 1)
        XCTAssertNotNil(overview.commits)

        let tables = try await insights.tables()
        let names = Set(tables.map { "\($0.schema).\($0.name)" })
        for t in ["public.customers", "public.orders", "public.order_items", "public.products", "analytics.events"] {
            XCTAssertTrue(names.contains(t), "missing \(t) in \(names)")
        }
        XCTAssertTrue(tables.allSatisfy { $0.totalBytes >= $0.tableBytes })

        let indexes = try await insights.indexReport()
        XCTAssertTrue(indexes.errors.isEmpty, "\(indexes.errors)")
        XCTAssertFalse(indexes.largest.isEmpty)
        XCTAssertTrue(indexes.unused.allSatisfy { !$0.isPrimary && !$0.isUnique && ($0.scans ?? 0) == 0 })

        // pg_stat_statements is not installed on the test server: the report explains instead of failing.
        let statements = try await insights.statements()
        XCTAssertNil(statements.installedSchema)
        XCTAssertTrue(statements.byTotalTime.isEmpty)

        _ = try await insights.blocking()
        _ = try await insights.longTransactions(minSeconds: 60)
        let vacuum = try await insights.vacuumReport()
        XCTAssertTrue(vacuum.errors.isEmpty, "\(vacuum.errors)")
        XCTAssertTrue(vacuum.xidAges.contains { $0.database == "shop" })

        // Threshold 0 lists every sequence with its owning column.
        let sequences = try await insights.sequences(threshold: 0)
        let products = try XCTUnwrap(sequences.first { $0.name == "products_id_seq" })
        XCTAssertEqual(products.table, "products")
        XCTAssertEqual(products.column, "id")
        XCTAssertTrue(products.usedFraction >= 0 && products.usedFraction < 0.75)
        let near = try await insights.sequences(threshold: 0.75)
        XCTAssertTrue(near.allSatisfy { $0.usedFraction > 0.75 })
    }

    /// Duplicate and unused detection on a table created inside a transaction that is rolled back
    /// (temp schemas are excluded by design).
    func testDuplicateAndUnusedIndexDetection() async throws {
        let client = try TestDB.pgClient()
        defer { client.close() }
        _ = try await client.query("BEGIN")
        do {
            _ = try await client.query("CREATE TABLE public.insights_dup_test (a int, b int, c text)")
            _ = try await client.query("CREATE INDEX insights_dup_ab1 ON public.insights_dup_test (a, b)")
            _ = try await client.query("CREATE INDEX insights_dup_ab2 ON public.insights_dup_test (a, b)")
            _ = try await client.query("CREATE INDEX insights_dup_c ON public.insights_dup_test (c)")
            let insights = PostgresInsights(client: client)
            let groups = try await insights.duplicateIndexes()
            let group = try XCTUnwrap(groups.first { $0.table == "insights_dup_test" }, "\(groups.map(\.table))")
            XCTAssertEqual(Set(group.indexes.map(\.name)), ["insights_dup_ab1", "insights_dup_ab2"])
            let unused = try await insights.unusedIndexes()
            XCTAssertTrue(unused.contains { $0.name == "insights_dup_c" })
        } catch {
            _ = try? await client.query("ROLLBACK")
            throw error
        }
        _ = try await client.query("ROLLBACK")
    }

    /// A real lock wait: session A holds an advisory lock in an open transaction, B waits for it.
    @MainActor
    func testBlockingLongTransactionAndProcessListCancel() async throws {
        let a = try TestDB.pgClient(label: "holder")
        let b = try TestDB.pgClient(label: "waiter")
        let key = Int.random(in: 1_000_000...9_000_000)
        defer {
            b.close()
            a.close()
        }
        _ = try await a.query("SET application_name = 'insights-test-holder'")
        _ = try await b.query("SET application_name = 'insights-test-waiter'")
        _ = try await a.query("BEGIN")
        _ = try await a.query("SELECT pg_advisory_xact_lock(\(key))")
        let waiter = Task { try await b.query("SELECT pg_advisory_xact_lock(\(key))") }

        let observer = try TestDB.pgClient(label: "observer")
        defer { observer.close() }
        let insights = PostgresInsights(client: observer)
        var pair: BlockingPair?
        for _ in 0..<100 {
            pair = try await insights.blocking().first { $0.blockedQuery?.contains("\(key)") ?? false }
            if pair != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let found = try XCTUnwrap(pair, "blocked pair not reported")
        XCTAssertEqual(found.blockedApplication, "insights-test-waiter")
        XCTAssertEqual(found.blockingApplication, "insights-test-holder")
        XCTAssertEqual(found.blockingState, "idle in transaction")
        XCTAssertTrue(found.blockingQuery?.contains("\(key)") ?? false)

        // Idle-in-transaction sessions are always listed.
        let long = try await insights.longTransactions(minSeconds: 60)
        XCTAssertTrue(long.contains { $0.pid == found.blockingPID })

        // Process list: sees both sessions and cancels the waiter through confirmWrite.
        let ctx = try await TestDB.pgContext()
        let model = ProcessListModel(context: ctx)
        model.autoRefresh = false
        model.start()
        defer { model.stop() }
        let loaded1 = await TestDB.wait { model.processes.contains { $0.pid == found.blockedPID } }
        XCTAssertTrue(loaded1)
        let waiting = try XCTUnwrap(model.processes.first { $0.pid == found.blockedPID })
        XCTAssertEqual(waiting.blockedBy, [found.blockingPID])
        XCTAssertFalse(model.processes.contains { $0.isSelf && model.visible.contains($0) }, "own backend is hidden by default")
        model.filter = "insights-test-"
        XCTAssertEqual(Set(model.visible.map(\.pid)), [found.blockedPID, found.blockingPID])

        // Declined confirmation sends nothing.
        ctx.allowWrites = false
        let declined = await model.send(.cancel, to: waiting)
        XCTAssertFalse(declined)
        ctx.allowWrites = true
        let sent = await model.send(.cancel, to: waiting)
        XCTAssertTrue(sent)
        do {
            _ = try await waiter.value
            XCTFail("waiter should have been cancelled")
        } catch {
            XCTAssertEqual((error as? DatabaseError)?.sqlState, "57014", error.insightsMessage)
        }
        XCTAssertTrue(ctx.toasts.contains { $0.contains("\(found.blockedPID)") })
        _ = try await a.query("ROLLBACK")
    }

    @MainActor
    func testDashboardModelLoadsAllSections() async throws {
        let ctx = try await TestDB.pgContext()
        let model = InsightsDashboardModel(context: ctx)
        model.start()
        defer { model.stop() }
        let loaded2 = await TestDB.wait { model.lastRefresh != nil && !model.isRefreshing }
        XCTAssertTrue(loaded2)
        XCTAssertNil(model.overview.error)
        XCTAssertNotNil(model.overview.value)
        XCTAssertNil(model.tables.error)
        XCTAssertNil(model.indexes.error)
        XCTAssertNil(model.statements.error)
        XCTAssertNotNil(model.statements.value)
        XCTAssertNil(model.blocking.error)
        XCTAssertNil(model.longTransactions.error)
        XCTAssertNil(model.sequences.error)
        XCTAssertNil(model.vacuum.error)
        model.openFix(title: "VACUUM orders", sql: InsightsFix.vacuumAnalyze(schema: "public", table: "orders"))
        XCTAssertEqual(ctx.openedQueries.last?.run, false)
    }

    @MainActor
    func testExplainReadWithAnalyze() async throws {
        let ctx = try await TestDB.pgContext()
        let sql = "SELECT c.email, count(o.id) FROM customers c JOIN orders o ON o.customer_id = c.id GROUP BY c.email ORDER BY 2 DESC LIMIT 10;"
        let model = ExplainPlanModel(context: ctx, sql: sql)
        defer { model.stop() }
        XCTAssertTrue(model.analyze, "ANALYZE defaults on for reads")
        await model.run()
        XCTAssertNil(model.error)
        let plan = try XCTUnwrap(model.plan)
        XCTAssertTrue(plan.isAnalyze)
        XCTAssertNotNil(plan.executionTime)
        XCTAssertFalse(model.shownRolledBack)
        XCTAssertTrue(plan.nodes.contains { $0.relationName == "customers" })
        XCTAssertNotNil(plan.mostExpensiveNodeID)

        model.showText = true
        let loaded3 = await TestDB.wait { model.textPlan != nil && !model.isRunning }
        XCTAssertTrue(loaded3)
        XCTAssertTrue(model.textPlan?.contains("Execution Time") ?? false, model.textPlan ?? "")
        XCTAssertEqual(model.copyText, model.textPlan)
    }

    @MainActor
    func testExplainAnalyzeOfWriteIsRolledBack() async throws {
        let ctx = try await TestDB.pgContext()
        let probe = try TestDB.pgClient()
        defer { probe.close() }
        func snapshot() async throws -> [String?] {
            let r = try await probe.query("SELECT (SELECT count(*) FROM audit_log)::text, (SELECT string_agg(price::text, ',' ORDER BY id) FROM products WHERE id <= 3)")
            return r.rows.first ?? []
        }
        let before = try await snapshot()
        let model = ExplainPlanModel(context: ctx, sql: "UPDATE products SET price = price + 1 WHERE id <= 3")
        defer { model.stop() }
        XCTAssertFalse(model.analyze, "ANALYZE defaults off for writes")
        XCTAssertFalse(model.analyzeExecutesWrite)

        await model.run()
        XCTAssertNil(model.error)
        XCTAssertFalse(model.plan?.isAnalyze ?? true)

        // Declined confirmation: nothing runs.
        model.analyze = true
        XCTAssertTrue(model.analyzeExecutesWrite)
        ctx.allowWrites = false
        await model.run()
        XCTAssertNotNil(model.error)
        XCTAssertFalse(model.plan?.isAnalyze ?? true)

        ctx.allowWrites = true
        await model.run()
        XCTAssertNil(model.error)
        let plan = try XCTUnwrap(model.plan)
        XCTAssertTrue(plan.isAnalyze)
        XCTAssertTrue(model.shownRolledBack)
        XCTAssertEqual(plan.root.displayName, "Update")
        XCTAssertTrue(plan.triggers.contains { $0.name == "products_audit" })
        let after = try await snapshot()
        XCTAssertEqual(before, after, "EXPLAIN ANALYZE of a write must be rolled back")
    }

    @MainActor
    func testExplainErrorsAreReported() async throws {
        let ctx = try await TestDB.pgContext()
        let model = ExplainPlanModel(context: ctx, sql: "SELECT * FROM no_such_table_insights")
        defer { model.stop() }
        await model.run()
        XCTAssertTrue(model.error?.contains("no_such_table_insights") ?? false, model.error ?? "nil")
        XCTAssertNil(model.plan)
    }

    /// RDS-like non-superuser: sections degrade instead of failing the dashboard.
    func testNonSuperuserDegradesGracefully() async throws {
        let admin = try TestDB.pgClient(label: "admin")
        defer { admin.close() }
        let role = "mtp_insights_\(Int.random(in: 100_000...999_999))"
        let password = UUID().uuidString
        _ = try await admin.query("CREATE ROLE \(role) LOGIN PASSWORD '\(password)'")
        func dropRole() async { _ = try? await admin.query("DROP ROLE IF EXISTS \(role)") }
        do {
            let s = try TestDB.pgSpec()
            var config = s.config
            config.user = role
            let client = DBClient(config: config, secrets: ConnectionSecrets(password: password))
            defer { client.close() }
            do {
                _ = try await client.connect()
            } catch {
                await dropRole()
                throw XCTSkip("cannot log in as a temporary role: \(error.insightsMessage)")
            }
            let insights = PostgresInsights(client: client)
            let overview = try await insights.overview()
            XCTAssertNotNil(overview.serverVersion)
            _ = try await insights.tables()
            _ = try await insights.indexReport()
            _ = try await insights.statements()
            _ = try await insights.blocking()
            _ = try await insights.longTransactions()
            _ = try await insights.vacuumReport()
            do { _ = try await insights.sequences() } catch { XCTAssertFalse(error.insightsMessage.isEmpty) }
            client.close()
        } catch {
            await dropRole()
            throw error
        }
        await dropRole()
    }

    // MARK: SQLite

    @MainActor
    func testSQLiteInsightsAndExplain() async throws {
        let path = NSTemporaryDirectory() + "mtp-insights-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let ctx = try await TestDB.sqliteContext(path: path)
        _ = try await ctx.client.query("""
            CREATE TABLE a (id INTEGER PRIMARY KEY, name TEXT);
            CREATE TABLE "b c" (id INTEGER PRIMARY KEY, a_id INTEGER REFERENCES a(id));
            CREATE INDEX b_a ON "b c"(a_id);
            INSERT INTO a(name) VALUES ('one'), ('two'), ('three');
            INSERT INTO "b c"(a_id) VALUES (1);
            """)
        let stats = try await SQLiteInsights(client: ctx.client).stats()
        XCTAssertGreaterThan(stats.pageCount ?? 0, 0)
        XCTAssertGreaterThan(stats.pageSize ?? 0, 0)
        XCTAssertEqual(stats.freelistCount, 0)
        XCTAssertEqual(stats.tables.map(\.name), ["a", "b c"])
        XCTAssertEqual(stats.tables.map(\.rows), [3, 1])
        let check = try await SQLiteInsights(client: ctx.client).integrityCheck()
        XCTAssertEqual(check, ["ok"])

        let model = SQLiteInsightsModel(context: ctx)
        model.start()
        defer { model.stop() }
        let loaded4 = await TestDB.wait { model.stats.value != nil }
        XCTAssertTrue(loaded4)
        await model.runIntegrityCheck()
        XCTAssertEqual(model.integrity, ["ok"])
        XCTAssertEqual(model.foreignKeys, [])

        let explain = ExplainPlanModel(context: ctx, sql: "EXPLAIN QUERY PLAN SELECT * FROM a JOIN \"b c\" ON \"b c\".a_id = a.id ORDER BY a.name")
        defer { explain.stop() }
        XCTAssertFalse(explain.analyze)
        await explain.run()
        XCTAssertNil(explain.error)
        let nodes = try XCTUnwrap(explain.sqlitePlan).flatMap(\.flattened)
        XCTAssertFalse(nodes.isEmpty)
        XCTAssertTrue(nodes.contains { $0.detail.contains("b_a") || $0.detail.contains("b c") }, nodes.map(\.detail).joined(separator: "\n"))
        XCTAssertNotNil(explain.textPlan)

        let processes = ProcessListModel(context: ctx)
        XCTAssertFalse(processes.isSupported)
    }
}
