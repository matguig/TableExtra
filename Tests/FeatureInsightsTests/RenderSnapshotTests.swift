import AppKit
import SwiftUI
import XCTest
import MTPCore
import MTPUIKit
@testable import FeatureInsights

/// Visual check: renders the views to PNG files in MTP_RENDER_DIR (skipped when unset).
/// NSViewRepresentable content (ResultTableView, CodeView, Table) renders as a placeholder.
@MainActor
final class RenderSnapshotTests: XCTestCase {
    func outputDir() throws -> URL {
        guard let dir = ProcessInfo.processInfo.environment["MTP_RENDER_DIR"], !dir.isEmpty else {
            throw XCTSkip("MTP_RENDER_DIR not set")
        }
        let url = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func render<V: View>(_ view: V, size: CGSize, to url: URL) throws {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.nsImage, "render failed")
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: url)
    }

    func testRenderDashboard() async throws {
        let dir = try outputDir()
        let ctx = try await TestDB.pgContext()
        let model = InsightsDashboardModel(context: ctx)
        model.start()
        defer { model.stop() }
        let loaded = await TestDB.wait { model.lastRefresh != nil && !model.isRefreshing }
        XCTAssertTrue(loaded)
        try render(InsightsDashboardContent(model: model), size: CGSize(width: 1100, height: 2600),
                   to: dir.appendingPathComponent("dashboard.png"))
        // ScrollView content is blank under ImageRenderer: render the sections on their own too.
        try render(DashboardSections(model: model).padding(16).background(Color(nsColor: .windowBackgroundColor)),
                   size: CGSize(width: 1100, height: 3200), to: dir.appendingPathComponent("dashboard-sections.png"))
    }

    func testRenderProcessList() async throws {
        let dir = try outputDir()
        let ctx = try await TestDB.pgContext()
        let model = ProcessListModel(context: ctx)
        model.autoRefresh = false
        model.showIdle = true
        model.start()
        defer { model.stop() }
        let loaded = await TestDB.wait { model.lastRefresh != nil }
        XCTAssertTrue(loaded)
        model.selection = model.visible.first?.pid
        try render(ProcessListContent(model: model), size: CGSize(width: 1100, height: 600),
                   to: dir.appendingPathComponent("process-list.png"))
        try render(ProcessListView(context: try await TestDB.sqliteContext(path: NSTemporaryDirectory() + "mtp-render-\(UUID().uuidString).db")),
                   size: CGSize(width: 700, height: 300), to: dir.appendingPathComponent("process-list-sqlite.png"))
    }

    func testRenderExplain() async throws {
        let dir = try outputDir()
        let ctx = try await TestDB.pgContext()
        let sql = """
            SELECT c.country, count(*), sum(oi.quantity * oi.unit_price)
            FROM order_items oi JOIN orders o ON o.id = oi.order_id JOIN customers c ON c.id = o.customer_id
            WHERE o.status = 'paid' GROUP BY c.country ORDER BY 3 DESC LIMIT 5
            """
        let model = ExplainPlanModel(context: ctx, sql: sql)
        defer { model.stop() }
        await model.run()
        XCTAssertNil(model.error)
        if let first = model.plan?.nodes.dropFirst(3).first { model.toggleDetails(first.id) }
        try render(ExplainPlanContent(model: model), size: CGSize(width: 1100, height: 900),
                   to: dir.appendingPathComponent("explain-analyze.png"))
        if let plan = model.plan {
            try render(PlanTreeView(model: model, plan: plan).padding(12).background(Color(nsColor: .windowBackgroundColor)),
                       size: CGSize(width: 1100, height: 900), to: dir.appendingPathComponent("explain-tree.png"))
        }

        let write = ExplainPlanModel(context: ctx, sql: "UPDATE products SET price = price WHERE id <= 5")
        defer { write.stop() }
        write.analyze = true
        await write.run()
        XCTAssertNil(write.error)
        try render(ExplainPlanContent(model: write), size: CGSize(width: 1100, height: 450),
                   to: dir.appendingPathComponent("explain-write.png"))
    }

    func testRenderSQLite() async throws {
        let dir = try outputDir()
        let path = NSTemporaryDirectory() + "mtp-render-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let ctx = try await TestDB.sqliteContext(path: path)
        _ = try await ctx.client.query("""
            CREATE TABLE a (id INTEGER PRIMARY KEY, name TEXT);
            CREATE TABLE b (id INTEGER PRIMARY KEY, a_id INTEGER REFERENCES a(id));
            CREATE INDEX b_a ON b(a_id);
            INSERT INTO a(name) VALUES ('one'), ('two');
            """)
        let model = SQLiteInsightsModel(context: ctx)
        model.start()
        defer { model.stop() }
        let loaded = await TestDB.wait { model.stats.value != nil }
        XCTAssertTrue(loaded)
        await model.runIntegrityCheck()
        try render(SQLiteInsightsContent(model: model), size: CGSize(width: 900, height: 700),
                   to: dir.appendingPathComponent("sqlite-insights.png"))
        try render(SQLiteInsightsSections(model: model).padding(16).background(Color(nsColor: .windowBackgroundColor)),
                   size: CGSize(width: 900, height: 700), to: dir.appendingPathComponent("sqlite-sections.png"))

        let explain = ExplainPlanModel(context: ctx, sql: "SELECT * FROM a JOIN b ON b.a_id = a.id ORDER BY a.name")
        defer { explain.stop() }
        await explain.run()
        try render(ExplainPlanContent(model: explain), size: CGSize(width: 900, height: 350),
                   to: dir.appendingPathComponent("explain-sqlite.png"))
        if let nodes = explain.sqlitePlan {
            try render(SQLitePlanTreeView(nodes: nodes).padding(12).background(Color(nsColor: .windowBackgroundColor)),
                       size: CGSize(width: 900, height: 200), to: dir.appendingPathComponent("explain-sqlite-tree.png"))
        }
    }

    /// Renders through a real NSHostingView in an offscreen window so the AppKit-backed `Table` draws
    /// (ImageRenderer only shows a placeholder for it).
    func renderHosted<V: View>(_ view: V, size: CGSize, dark: Bool, to url: URL) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: url)
        window.orderOut(nil)
    }

    /// Canned pg_stat_statements rows (the test server has no pg_stat_statements).
    static func cannedStatements() -> StatementsReport {
        func stat(_ query: String, calls: Int64, total: Double, max: Double, rows: Int64, pct: Double, hit: Int64 = 990, read: Int64 = 10) -> StatementStat {
            StatementStat(id: query, query: query, calls: calls, totalMs: total, meanMs: total / Double(calls), maxMs: max, rows: rows,
                          sharedHit: hit, sharedRead: read, tempWritten: nil, user: "mtp", percentOfTotal: pct)
        }
        let rows = [
            stat("SELECT o.id, o.status, c.email FROM orders o JOIN customers c ON c.id = o.customer_id WHERE o.created_at > $1 ORDER BY o.created_at DESC", calls: 244, total: 47_030, max: 649, rows: 19_032, pct: 31.6),
            stat("WITH recent AS ( -- last 30 days\n SELECT * FROM order_items WHERE order_id = ANY($1) ) SELECT product_id, sum(quantity) FROM recent GROUP BY 1", calls: 80, total: 38_000, max: 735, rows: 8_166, pct: 25.5),
            stat("SELECT name FROM pg_timezone_names", calls: 72, total: 27_220, max: 1_500, rows: 86_112, pct: 18.3, hit: 0, read: 0),
            stat("UPDATE products SET stock = stock - $1 WHERE id = $2 AND stock >= $1", calls: 1_906, total: 15_920, max: 621, rows: 1_906, pct: 10.7),
            stat("INSERT INTO audit_log (actor, action, payload) VALUES ($1, $2, $3::jsonb)", calls: 1_906, total: 9_390, max: 21, rows: 1_906, pct: 6.3),
            stat("SELECT count(*) FROM customers WHERE country = 'FR'", calls: 72, total: 1_810, max: 91, rows: 72, pct: 1.2),
            stat("CREATE INDEX CONCURRENTLY IF NOT EXISTS orders_created_idx ON orders (created_at)", calls: 1, total: 930, max: 930, rows: 0, pct: 0.6),
            stat("-- refresh dashboard\nREFRESH MATERIALIZED VIEW daily_revenue", calls: 8, total: 760, max: 155, rows: 0, pct: 0.5),
        ]
        return StatementsReport(installedSchema: "public", installedVersion: "1.10", availableOnServer: true, preloadLibraries: "pg_stat_statements",
                                canReadAllStats: true, byTotalTime: rows, byMeanTime: rows.sorted { $0.meanMs > $1.meanMs }, queryError: nil)
    }

    func testRenderSlowQueriesCanned() async throws {
        let dir = try outputDir()
        let config = ConnectionConfig(name: "canned", driver: .postgres, host: "127.0.0.1", port: 1, user: "mtp", database: "shop", sslMode: .disable)
        let ctx = StandaloneWorkspaceContext(connection: config, secrets: ConnectionSecrets())
        let model = InsightsDashboardModel(context: ctx)
        model.statements = SectionState(value: Self.cannedStatements())
        model.overview = SectionState(value: OverviewStats(serverVersion: "16.4", databaseBytes: 15_300_000, connections: 12, activeConnections: 3,
                                                           idleInTransaction: 1, maxConnections: 100, blocksHit: 999_000, blocksRead: 1_000))
        model.blocking = SectionState(value: [])
        model.longTransactions = SectionState(value: [])
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            for width in [1100.0, 760.0] {
                let view = VStack(alignment: .leading, spacing: DS.Space.xxl) {
                    DashboardHeadline(model: model)
                    SlowQueriesSection(model: model)
                }
                .padding(16)
                .background(DS.Palette.canvas)
                try renderHosted(view, size: CGSize(width: width, height: 520), dark: dark,
                                 to: dir.appendingPathComponent("slow-queries-\(Int(width))-\(suffix).png"))
            }
            try renderHosted(SlowQueriesSection(model: model, tab: .mean).padding(16).background(DS.Palette.canvas),
                             size: CGSize(width: 1100, height: 420), dark: dark,
                             to: dir.appendingPathComponent("slow-queries-mean-\(suffix).png"))
        }
    }
}
