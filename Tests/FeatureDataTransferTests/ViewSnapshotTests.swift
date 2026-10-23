import AppKit
import MTPCore
import MTPUIKit
import SwiftUI
import XCTest
@testable import FeatureDataTransfer

/// Renders the sheets to PNG for a visual check (MTP_SNAPSHOT_DIR=<folder>); skipped otherwise.
/// NSViewRepresentable content (the result grid) renders as a placeholder; that is expected.
@MainActor
final class ViewSnapshotTests: XCTestCase {
    func snapshotDir() throws -> URL {
        guard let dir = ProcessInfo.processInfo.environment["MTP_SNAPSHOT_DIR"] else { throw XCTSkip("MTP_SNAPSHOT_DIR not set") }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Renders in a real (offscreen) window so AppKit controls draw: ideal size + a small window, light and dark.
    func snap<V: View>(_ view: V, _ name: String) throws {
        let dir = try snapshotDir()
        _ = NSApplication.shared
        let probe = NSHostingController(rootView: view)
        let ideal = NSHostingController(rootView: view.fixedSize()).sizeThatFits(in: CGSize(width: 4000, height: 4000))
        let sizes: [(String, CGSize)] = [("", CGSize(width: min(max(ideal.width, 300), 1400), height: min(max(ideal.height, 200), 1000))),
                                         ("-small", probe.sizeThatFits(in: CGSize(width: 1, height: 1)))]
        for (suffix, size) in sizes {
            for dark in [false, true] {
                let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.15))
                host.layoutSubtreeIfNeeded()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return XCTFail("render failed: \(name)") }
                host.cacheDisplay(in: host.bounds, to: rep)
                let png = rep.representation(using: .png, properties: [:])
                try png?.write(to: dir.appendingPathComponent("\(name)\(suffix)-\(dark ? "dark" : "light").png"))
                window.contentView = nil
            }
        }
    }

    func context() async throws -> StandaloneWorkspaceContext {
        let (config, password) = try pgSpec()
        var c = config
        c.name = "Local shop"
        let ctx = StandaloneWorkspaceContext(connection: c, secrets: ConnectionSecrets(password: password))
        try await ctx.prepare()
        return ctx
    }

    func testExportSnapshots() async throws {
        _ = try snapshotDir()
        let ctx = try await context()
        let result = try await ctx.client.query("SELECT id, email, full_name, country, metadata, created_at FROM customers ORDER BY id LIMIT 30")
        let csv = ExportModel(context: ctx, source: .result(result, suggestedName: "customers", tableName: "public.customers"))
        try snap(ExportView(model: csv, onClose: {}), "export-result-csv")
        let sql = ExportModel(context: ctx, source: .result(result, suggestedName: "customers", tableName: "public.customers"))
        sql.format = .sqlInsert
        sql.options.sqlBatchSize = 5
        try snap(ExportView(model: sql, onClose: {}), "export-result-sql")
        XCTAssertTrue(csv.previewText.hasPrefix("id,email,full_name,country,metadata,created_at\n1,"), csv.previewText)
        XCTAssertTrue(sql.previewText.hasPrefix("INSERT INTO public.customers (id, email, full_name, country, metadata, created_at) VALUES"), sql.previewText)
        XCTAssertEqual(sql.previewText.components(separatedBy: "INSERT INTO").count - 1, 3, "12 preview rows in batches of 5")
        XCTAssertTrue(tablesWritesFolder(), "several tables in CSV go to a folder")
        let tables = ExportModel(context: ctx, source: .tables(schema: "public", names: ["customers", "orders", "products"]))
        tables.phase = .running
        tables.fraction = 0.42
        tables.progressText = "orders (2 of 3) — 5,000 rows · 7,000 total"
        try snap(ExportView(model: tables, onClose: {}), "export-tables-running")
        try snap(ExportView(model: ExportModel(context: ctx, source: .tables(schema: "public", names: ["orders"])), onClose: {}), "export-table-idle")
        let done = ExportModel(context: ctx, source: .tables(schema: "public", names: ["orders"]))
        done.format = .json
        done.phase = .done(files: [URL(fileURLWithPath: "/Users/me/Desktop/orders.json")], rows: 1234, duration: 0.8)
        try snap(ExportView(model: done, onClose: {}), "export-table-done")
        ctx.client.close()
    }

    func tablesWritesFolder() -> Bool {
        let m = ExportModel(context: nil, source: .tables(schema: "public", names: ["a", "b"]))
        let folder = m.writesFolder
        m.format = .sqlInsert
        return folder && !m.writesFolder
    }

    func testImportSnapshots() async throws {
        _ = try snapshotDir()
        let ctx = try await context()
        let url = try tempDir().appendingPathComponent("New Customers.csv")
        try Data("Email;Full Name;Country;Signed Up;Score\na@x.io;Ann;FR;2024-01-02;1.5\nb@x.io;Bob;DE;2024-02-03;2\n".utf8).write(to: url)

        let empty = ImportModel(context: ctx, schema: "public", table: nil)
        try snap(ImportCSVView(model: empty, onClose: {}), "import-empty")

        let newTable = ImportModel(context: ctx, schema: "public", table: nil)
        await newTable.loadTables()
        await newTable.load(url)
        XCTAssertEqual(newTable.newTableName, "new_customers")
        try snap(ImportCSVView(model: newTable, onClose: {}), "import-new-table")

        let existing = ImportModel(context: ctx, schema: "public", table: "customers")
        await existing.loadTables()
        await existing.load(url)
        XCTAssertEqual(existing.columns.map(\.target), ["email", "full_name", "country", "", ""])
        var report = ImportReport()
        report.inserted = 2
        report.skipped = 1
        report.committed = true
        report.duration = 0.2
        report.errors = [ImportRowError(line: 4, message: "ERROR: invalid input syntax for type integer: \"x\"")]
        existing.report = report
        try snap(ImportCSVView(model: existing, onClose: {}), "import-existing-report")
        ctx.client.close()
    }

    func testBackupRestoreSnapshots() async throws {
        _ = try snapshotDir()
        let (config, password) = try pgSpec()
        var c = config
        c.name = "Local shop"
        let backup = BackupModel(connection: c, database: "shop", secrets: ConnectionSecrets(password: password))
        await backup.load()
        XCTAssertNotNil(backup.serverMajor)
        XCTAssertFalse(backup.tables.isEmpty)
        backup.tableMode = .except
        backup.selectedTables = [PGTableRef(schema: "public", name: "audit_log")]
        backup.log.append("pg_dump: dumping contents of table \"public.customers\"")
        backup.log.append("pg_dump: error: example error line")
        try snap(BackupView(model: backup, onClose: {}), "backup-postgres")

        var prod = c
        prod.environment = .production
        prod.safety = .confirmWrites
        let restore = RestoreModel(connection: prod, database: "shop", secrets: ConnectionSecrets(password: password))
        await restore.load()
        restore.file = URL(fileURLWithPath: "/Users/me/Backups/shop-20261023-1000.dump")
        restore.fileFormat = .custom
        restore.pickTool()
        restore.confirmation = "sh"
        try snap(RestoreView(model: restore, onClose: {}), "restore-production")

        var ro = c
        ro.safety = .readOnly
        try snap(RestoreView(model: RestoreModel(connection: ro, database: nil, secrets: ConnectionSecrets()), onClose: {}), "restore-readonly")

        var lite = ConnectionConfig(name: "Local file", driver: .sqlite)
        lite.filePath = "/Users/me/data/app.sqlite"
        let sqliteBackup = BackupModel(connection: lite, database: nil, secrets: ConnectionSecrets())
        await sqliteBackup.load()
        try snap(BackupView(model: sqliteBackup, onClose: {}), "backup-sqlite")
    }

    func testTablePlusSnapshots() throws {
        _ = try snapshotDir()
        let dir = try tempDir()
        let data = try TablePlusMigrationTests.makeFakeTablePlus(in: dir)
        let store = ConnectionStore(url: dir.appendingPathComponent("connections.json"))
        let history = HistoryStore(url: dir.appendingPathComponent("history.sqlite"))
        let model = TablePlusImportModel(importer: TablePlusImporter(dataDirectory: data), store: store, history: history)
        model.load()
        XCTAssertEqual(model.preview?.connections.count, 3)
        try snap(TablePlusImportView(model: model, onClose: {}), "tableplus-preview")

        model.summary = TablePlusImportSummary(connections: 3, groups: 1, passwords: 0, historyEntries: 3)
        try snap(TablePlusImportView(model: model, onClose: {}), "tableplus-summary")

        let missing = TablePlusImportModel(importer: TablePlusImporter(dataDirectory: dir.appendingPathComponent("none")), store: store, history: history)
        missing.load()
        try snap(TablePlusImportView(model: missing, onClose: {}), "tableplus-missing")
    }
}
