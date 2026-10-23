import MTPCore
import MTPUIKit
import XCTest
@testable import FeatureDataTransfer

/// Drives the sheet models end to end against MTP_TEST_PG (temporary tables and databases only).
@MainActor
final class ViewModelTests: XCTestCase {
    func context() async throws -> StandaloneWorkspaceContext {
        let (config, password) = try pgSpec()
        let ctx = StandaloneWorkspaceContext(connection: config, secrets: ConnectionSecrets(password: password))
        try await ctx.prepare()
        addTeardownBlock { await MainActor.run { ctx.client.close() } }
        return ctx
    }

    func testExportModelWritesFolder() async throws {
        let ctx = try await context()
        let dir = try tempDir()
        let model = ExportModel(context: ctx, source: .tables(schema: "public", names: ["customers", "products"]))
        model.format = .jsonLines
        XCTAssertTrue(model.writesFolder)
        model.export(to: dir)
        await model.task?.value
        guard case .done(let files, let rows, _) = model.phase else { return XCTFail("\(model.phase)") }
        XCTAssertEqual(files.map(\.lastPathComponent).sorted(), ["customers.jsonl", "products.jsonl"])
        let lines = try String(contentsOf: dir.appendingPathComponent("customers.jsonl"), encoding: .utf8).split(separator: "\n")
        XCTAssertGreaterThan(rows, lines.count)
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])

        let result = try await ctx.client.query("SELECT 1 AS n, 'a|b' AS s, NULL::text AS z")
        let r = ExportModel(context: ctx, source: .result(result, suggestedName: "q", tableName: nil))
        r.format = .markdown
        let md = dir.appendingPathComponent("q.md")
        r.export(to: md)
        await r.task?.value
        XCTAssertEqual(try String(contentsOf: md, encoding: .utf8), "| n | s | z |\n| ---: | --- | --- |\n| 1 | a\\|b |  |\n")
    }

    func testImportModelCreatesTable() async throws {
        let ctx = try await context()
        let table = "mtp_dt_vm_\(UUID().uuidString.prefix(8).lowercased())"
        addTeardownBlock { _ = try? await self.pgClient().query("DROP TABLE IF EXISTS public.\(table)") }
        let url = try tempDir().appendingPathComponent("\(table).csv")
        try Data("Code\tLabel\tWhen\n1\tone\t2024-01-01\n2\ttwo\t2024-01-02\n".utf8).write(to: url)

        let model = ImportModel(context: ctx, schema: "public", table: nil)
        await model.loadTables()
        await model.load(url)
        XCTAssertEqual(model.settings.delimiter, UInt8(ascii: "\t"))
        XCTAssertEqual(model.newTableName, table)
        XCTAssertEqual(model.columns.map(\.sqlType), ["integer", "text", "date"])

        ctx.allowWrites = false
        model.runImport()
        await model.task?.value
        XCTAssertNil(model.report, "declined confirmation writes nothing")
        let none = try await ctx.client.query("SELECT to_regclass($1) IS NULL", ["public.\(table)"])
        XCTAssertEqual(none.rows[0][0], "t")

        ctx.allowWrites = true
        model.runImport()
        await model.task?.value
        XCTAssertEqual(model.report?.committed, true, model.report?.failure ?? "")
        XCTAssertEqual(model.report?.inserted, 2)
        XCTAssertEqual(ctx.toasts.last, "Imported 2 rows into \(table)")
        let rows = try await ctx.client.query("SELECT code, label, \"when\"::text FROM public.\(table) ORDER BY code")
        XCTAssertEqual(rows.rows, [["1", "one", "2024-01-01"], ["2", "two", "2024-01-02"]])
        XCTAssertEqual(model.blocker, "A table named \(table) already exists")
    }

    func testBackupAndRestoreModels() async throws {
        let (config, password) = try pgSpec()
        let secrets = ConnectionSecrets(password: password)
        let dir = try tempDir()
        let backup = BackupModel(connection: config, database: "shop", secrets: secrets)
        await backup.load()
        guard backup.tool != nil else { throw XCTSkip("pg_dump not installed") }
        backup.options.format = .plain
        backup.options.content = .schemaOnly
        backup.options.noOwner = true
        backup.options.noPrivileges = true
        backup.output = dir.appendingPathComponent("schema.sql")
        backup.start()
        await backup.task?.value
        guard case .success? = backup.resultMessage?.0 else { return XCTFail(backup.log.text) }
        XCTAssertTrue(backup.log.lines.first?.text.hasPrefix("$ ") == true)
        XCTAssertFalse(backup.log.text.contains(password), "password never logged")
        XCTAssertTrue(try String(contentsOf: backup.output, encoding: .utf8).contains("CREATE TABLE public.customers"))

        let admin = try pgClient()
        defer { admin.close() }
        let db = "mtp_restore_\(UUID().uuidString.prefix(8).lowercased())"
        _ = try await admin.query("CREATE DATABASE \(db)")
        do {
            let restore = RestoreModel(connection: config, database: db, secrets: secrets)
            await restore.load()
            restore.file = backup.output
            restore.fileFormat = BackupFileFormat.detect(backup.output)
            restore.pickTool()
            XCTAssertEqual(restore.toolName, "psql")
            XCTAssertNil(restore.blocker)
            restore.start()
            await restore.task?.value
            if case .success? = restore.resultMessage?.0 {} else { XCTFail("restore failed: \(String(describing: restore.resultMessage)) " + restore.log.text.suffix(500)) }
            let restored = try pgClient(database: db)
            let tables = try await restored.query("SELECT count(*) FROM pg_tables WHERE schemaname = 'public' AND tablename = 'customers'")
            XCTAssertEqual(tables.rows[0][0], "1")
            restored.close()
            try await Task.sleep(nanoseconds: 200_000_000)
        } catch {
            _ = try? await admin.query("DROP DATABASE IF EXISTS \(db) WITH (FORCE)")
            throw error
        }
        _ = try await admin.query("DROP DATABASE IF EXISTS \(db) WITH (FORCE)")

        var prod = config
        prod.environment = .production
        let guarded = RestoreModel(connection: prod, database: "shop", secrets: secrets)
        guarded.file = backup.output
        guarded.fileFormat = .plain
        guarded.tool = PGToolLocator.candidates("psql").first
        XCTAssertEqual(guarded.blocker, "Type shop to confirm")
        guarded.confirmation = "shop"
        XCTAssertNil(guarded.blocker)
        var ro = config
        ro.safety = .readOnly
        let readOnly = RestoreModel(connection: ro, database: nil, secrets: secrets)
        readOnly.file = backup.output
        XCTAssertEqual(readOnly.blocker, "This connection is read-only")
    }
}
