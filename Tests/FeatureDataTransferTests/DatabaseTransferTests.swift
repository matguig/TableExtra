import MTPCore
import XCTest
@testable import FeatureDataTransfer

/// Integration tests against MTP_TEST_PG. Every table or database they create is temporary and dropped.
final class DatabaseTransferTests: XCTestCase {
    func randomSuffix() -> String { UUID().uuidString.prefix(8).lowercased() }

    // MARK: Import

    func testCSVImportRoundTripIntoExistingTable() async throws {
        let client = try pgClient()
        let table = "mtp_dt_import_\(randomSuffix())"
        _ = try await client.query("""
            CREATE TABLE public.\(table) (id int PRIMARY KEY, name text, price numeric(10,2), active boolean,
                                           created timestamptz, meta jsonb, note text DEFAULT 'none')
            """)
        addTeardownBlock { _ = try? await client.query("DROP TABLE IF EXISTS public.\(table)") }

        let dir = try tempDir()
        let csv = dir.appendingPathComponent("people.csv")
        try Data(#"""
        ID;Name;Price;Active;Created;Meta;Ignored
        1;"Zoë; ""Z""";9.99;true;2024-01-02 10:00:00+00;{"a": [1, 2]};x
        2;"multi
        line";;f;;;y
        3;"";0;yes;2024-03-04T05:06:07Z;null;z
        oops;bad;1;t;;;w
        5;NULL;"12.5";no;2024-01-01;"{""k"": ""v""}";v

        """#.replacingOccurrences(of: "\n", with: "\r\n").utf8).write(to: csv)

        let settings = try ImportFileLoader.sniff(csv)
        XCTAssertEqual(settings.delimiter, UInt8(ascii: ";"))
        XCTAssertTrue(settings.hasHeader)
        let preview = try ImportFileLoader.preview(csv, kind: .delimited, settings: settings)
        XCTAssertEqual(preview.columns, ["ID", "Name", "Price", "Active", "Created", "Meta", "Ignored"])
        XCTAssertEqual(preview.rows.count, 5)
        XCTAssertEqual(preview.rows[1].line, 3)

        let details = try await Introspection.make(client).tableDetails(schema: "public", name: table)
        var columns = ImportMapping.mapByName(preview: preview, target: details.columns)
        XCTAssertEqual(columns.map(\.target), ["id", "name", "price", "active", "created", "meta", ""])
        XCTAssertEqual(columns.map(\.include), [true, true, true, true, true, true, false])
        columns[0].include = true

        var plan = ImportPlan(schema: "public", table: table, columns: columns, batchSize: 2, errorPolicy: .skip)
        var source = try ImportFileLoader.makeSource(csv, kind: .delimited, settings: settings)
        let report = await DataImporter.run(plan: plan, source: source, client: client) { _ in }
        XCTAssertNil(report.failure)
        XCTAssertTrue(report.committed)
        XCTAssertEqual(report.inserted, 4)
        XCTAssertEqual(report.skipped, 1)
        XCTAssertEqual(report.errors.first?.line, 6, "line of the bad record (after a two-line record)")
        XCTAssertTrue(report.errors.first?.message.contains("integer") == true, report.errors.first?.message ?? "")

        let r = try await client.query("SELECT id, name, price::text, active, to_char(created AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS'), meta::text, note FROM public.\(table) ORDER BY id")
        XCTAssertEqual(r.rows.count, 4)
        XCTAssertEqual(r.rows[0], ["1", "Zoë; \"Z\"", "9.99", "t", "2024-01-02 10:00:00", "{\"a\": [1, 2]}", "none"])
        XCTAssertEqual(r.rows[1], ["2", "multi\r\nline", nil, "f", nil, nil, "none"])
        XCTAssertEqual(r.rows[2][1], "", "quoted empty stays an empty string")
        XCTAssertEqual(r.rows[2][5], "null", "JSON null literal")
        XCTAssertEqual(r.rows[3][1], nil, "unquoted NULL marker")
        XCTAssertEqual(r.rows[3][2], "12.50")

        // Stop-on-error rolls everything back, including the truncate.
        plan.errorPolicy = .stop
        plan.truncateFirst = true
        source = try ImportFileLoader.makeSource(csv, kind: .delimited, settings: settings)
        let stopped = await DataImporter.run(plan: plan, source: source, client: client) { _ in }
        XCTAssertFalse(stopped.committed)
        XCTAssertTrue(stopped.failure?.hasPrefix("Line 6:") == true, stopped.failure ?? "")
        let count = try await client.query("SELECT count(*) FROM public.\(table)")
        XCTAssertEqual(count.rows[0][0], "4")
    }

    func testImportIntoNewTableWithInferredTypes() async throws {
        let client = try pgClient()
        let table = "mtp_dt_new_\(randomSuffix())"
        addTeardownBlock { _ = try? await client.query("DROP TABLE IF EXISTS public.\(table)") }
        let url = try tempDir().appendingPathComponent("new.csv")
        var text = "Order ID,Amount,Paid,Placed On,Placed At,Zip,Payload\n"
        for i in 1...1_234 {
            text += "\(i),\(i).25,\(i % 2 == 0 ? "true" : "false"),2024-02-\(String(format: "%02d", i % 28 + 1)),2024-02-01T10:00:00Z,0\(i % 9000 + 1000),\"{\"\"i\"\": \(i)}\"\n"
        }
        try Data(text.utf8).write(to: url)
        let settings = try ImportFileLoader.sniff(url)
        let preview = try ImportFileLoader.preview(url, kind: .delimited, settings: settings)
        XCTAssertFalse(preview.isComplete, "sample is capped below the file size")
        XCTAssertEqual(preview.inferredTypes, [.integer, .numeric, .boolean, .date, .timestamptz, .text, .json])
        let columns = ImportMapping.newTableColumns(preview: preview, dialect: client.dialect)
        XCTAssertEqual(columns.map(\.target), ["order_id", "amount", "paid", "placed_on", "placed_at", "zip", "payload"])

        let plan = ImportPlan(schema: "public", table: table, createTable: true, columns: columns, batchSize: 500)
        XCTAssertTrue(plan.previewSQL(client.dialect, rowCount: nil).contains("CREATE TABLE public.\"\(table)\"") ||
                      plan.previewSQL(client.dialect, rowCount: nil).contains("CREATE TABLE \"public\".\"\(table)\""))
        let source = try ImportFileLoader.makeSource(url, kind: .delimited, settings: settings)
        let fractions = LockedArray<Double>()
        let report = await DataImporter.run(plan: plan, source: source, client: client) { fractions.append($0.fraction) }
        XCTAssertNil(report.failure)
        XCTAssertEqual(report.inserted, 1_234)
        XCTAssertGreaterThanOrEqual(fractions.values.count, 3)
        let types = try await client.query("""
            SELECT column_name, data_type FROM information_schema.columns WHERE table_schema = 'public' AND table_name = $1 ORDER BY ordinal_position
            """, [table])
        XCTAssertEqual(types.rows.map { $0[1] ?? "" }, ["integer", "numeric", "boolean", "date", "timestamp with time zone", "text", "jsonb"])
        let zip = try await client.query("SELECT zip, payload->>'i' FROM public.\(table) WHERE order_id = 7")
        XCTAssertEqual(zip.rows[0], ["01007", "7"])
    }

    func testImportCancellationRollsBack() async throws {
        let client = try pgClient()
        let table = "mtp_dt_cancel_\(randomSuffix())"
        _ = try await client.query("CREATE TABLE public.\(table) (n int)")
        addTeardownBlock { _ = try? await client.query("DROP TABLE IF EXISTS public.\(table)") }
        let url = try tempDir().appendingPathComponent("n.csv")
        try Data(("n\n" + (1...20_000).map(String.init).joined(separator: "\n")).utf8).write(to: url)
        let settings = try ImportFileLoader.sniff(url)
        let preview = try ImportFileLoader.preview(url, kind: .delimited, settings: settings)
        let details = try await Introspection.make(client).tableDetails(schema: "public", name: table)
        let plan = ImportPlan(schema: "public", table: table, columns: ImportMapping.mapByName(preview: preview, target: details.columns), batchSize: 100)
        let source = try ImportFileLoader.makeSource(url, kind: .delimited, settings: settings)
        // Cancel from inside the run once a few batches went through (deterministic, unlike a timer).
        let task = Task {
            await DataImporter.run(plan: plan, source: source, client: client) { p in
                if p.inserted >= 300 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        let report = await task.value
        XCTAssertTrue(report.cancelled, "failure: \(report.failure ?? "-"), inserted \(report.inserted)")
        let count = try await client.query("SELECT count(*) FROM public.\(table)")
        XCTAssertEqual(count.rows[0][0], "0")
    }

    // MARK: Export

    func testStreamingTableExport() async throws {
        let client = try pgClient()
        let dir = try tempDir()
        let exporter = TableExporter(client: client, pageSize: 1_000)
        let seen = LockedArray<TableExportProgress>()
        let result = try await exporter.export(schema: "public", tables: ["customers", "products"], format: .csv, options: ExportOptions(),
                                               destination: dir) { seen.append($0) }
        XCTAssertEqual(result.files.map(\.lastPathComponent).sorted(), ["customers.csv", "products.csv"])
        let expected = try await client.query("SELECT (SELECT count(*) FROM customers), (SELECT count(*) FROM products)")
        XCTAssertEqual(result.rowsPerTable["customers"].map(String.init), expected.rows[0][0])
        XCTAssertEqual(result.rowsPerTable["products"].map(String.init), expected.rows[0][1])
        let csv = try Data(contentsOf: dir.appendingPathComponent("customers.csv"))
        let records = CSVParser.records(csv)
        XCTAssertEqual(records.count - 1, result.rowsPerTable["customers"])
        XCTAssertEqual(records[0].fields, ["id", "email", "full_name", "country", "metadata", "created_at"])
        XCTAssertEqual(records[1].fields[0], "1", "ordered by primary key")
        XCTAssertEqual(records.last?.fields[0], expected.rows[0][0])
        XCTAssertTrue(seen.values.contains { $0.table == "customers" && $0.rowsInTable == 1_000 })
        XCTAssertEqual(seen.values.last?.fraction ?? 0, 1, accuracy: 0.001)

        // JSON stream stays one valid document across pages.
        let jsonURL = dir.appendingPathComponent("orders.json")
        let j = try await exporter.export(schema: "public", tables: ["orders"], format: .json, options: ExportOptions(prettyJSON: false),
                                          destination: jsonURL) { _ in }
        let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [[String: Any]]
        XCTAssertEqual(parsed?.count, j.rows)
        XCTAssertNotNil(parsed?.first?["total"] as? NSNumber)
    }

    func testSQLExportReplaysIntoCopy() async throws {
        let client = try pgClient()
        let copy = "mtp_dt_sqlcopy_\(randomSuffix())"
        let dir = try tempDir()
        let url = dir.appendingPathComponent("dump.sql")
        // Full SQL export with DDL, then replay the INSERTs into a renamed copy of the table.
        let exporter = TableExporter(client: client, pageSize: 150)
        _ = try await exporter.export(schema: "public", tables: ["order_items", "products"], format: .sqlInsert,
                                      options: ExportOptions(sqlBatchSize: 70, includeCreateTable: true), destination: url) { _ in }
        let script = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(script.contains("CREATE TABLE \"public\".\"products\""), String(script.prefix(500)))
        let productsAt = script.range(of: "-- Table: public.products")!.lowerBound
        let itemsAt = script.range(of: "-- Table: public.order_items")!.lowerBound
        XCTAssertLessThan(productsAt, itemsAt, "referenced table first")

        _ = try await client.query("CREATE TABLE public.\(copy) (LIKE public.products INCLUDING ALL)")
        addTeardownBlock { _ = try? await client.query("DROP TABLE IF EXISTS public.\(copy)") }
        // Only the products INSERT statements, retargeted at the copy (never replayed into the real table).
        let statements = script[productsAt..<itemsAt].components(separatedBy: ";\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("INSERT INTO public.products ") }
            .map { $0.replacingOccurrences(of: "INSERT INTO public.products ", with: "INSERT INTO public.\(copy) ") }
        XCTAssertGreaterThan(statements.count, 1, "batches of 70 rows")
        for sql in statements { _ = try await client.query(sql) }
        let same = try await client.query("""
            SELECT (SELECT md5(string_agg(p::text, ',' ORDER BY id)) FROM products p) = (SELECT md5(string_agg(c::text, ',' ORDER BY id)) FROM public.\(copy) c)
            """)
        XCTAssertEqual(same.rows[0][0], "t")
    }

    func testExportCancellationRemovesFile() async throws {
        let client = try pgClient()
        let dir = try tempDir()
        let url = dir.appendingPathComponent("items.csv")
        let exporter = TableExporter(client: client, pageSize: 50)
        let task = Task {
            try await exporter.export(schema: "public", tables: ["order_items"], format: .csv, options: ExportOptions(), destination: url) { p in
                if p.rowsInTable >= 500 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let alive = try await client.query("SELECT 1")
        XCTAssertEqual(alive.rows[0][0], "1", "connection usable after a cancelled export")
        XCTAssertFalse(client.inTransaction)
    }

    // MARK: Backup / restore

    func testPgDumpAndRestoreRoundTrip() async throws {
        let (config, password) = try pgSpec()
        let admin = try pgClient()
        let versionNum = try await admin.query("SHOW server_version_num")
        let serverMajor = PGToolLocator.serverMajor(versionNum: Int(versionNum.rows[0][0] ?? "0") ?? 0)
        guard let dump = PGToolLocator.preferred("pg_dump", serverMajor: serverMajor, among: PGToolLocator.candidates("pg_dump")),
              let restore = PGToolLocator.preferred("pg_restore", serverMajor: serverMajor, among: PGToolLocator.candidates("pg_restore")),
              let psql = PGToolLocator.preferred("psql", serverMajor: serverMajor, among: PGToolLocator.candidates("psql")) else {
            throw XCTSkip("pg_dump / pg_restore / psql not installed")
        }
        XCTAssertGreaterThanOrEqual(dump.major, serverMajor)

        let dir = try tempDir()
        let archive = dir.appendingPathComponent("shop.dump")
        let source = PGConnectionTarget(config: config, password: password)
        var options = PGDumpOptions()
        options.noOwner = true
        options.compression = 6
        let lines = LockedArray<String>()
        let dumped = try await BackupEngine.pgDump(tool: dump, target: source, options: options, output: archive).run { lines.append($1) }
        XCTAssertTrue(dumped.succeeded, lines.values.suffix(10).joined(separator: "\n"))
        XCTAssertTrue(lines.values.contains { $0.contains("dumping contents of table") }, "--verbose output streamed")
        XCTAssertEqual(BackupFileFormat.detect(archive), .custom)

        let plain = dir.appendingPathComponent("shop.sql")
        var plainOptions = PGDumpOptions()
        plainOptions.format = .plain
        plainOptions.noOwner = true
        plainOptions.noPrivileges = true
        plainOptions.excludeTables = [PGTableRef(schema: "public", name: "audit_log")]
        let dumpedPlain = try await BackupEngine.pgDump(tool: dump, target: source, options: plainOptions, output: plain).run { _, _ in }
        XCTAssertTrue(dumpedPlain.succeeded)
        XCTAssertEqual(BackupFileFormat.detect(plain), .plain)

        // Restore each into a brand-new database, compare, then drop it.
        for (format, file) in [(BackupFileFormat.custom, archive), (.plain, plain)] {
            let dbName = "mtp_restore_\(randomSuffix())"
            _ = try await admin.query("CREATE DATABASE \(dbName)")
            do {
                let target = PGConnectionTarget(config: config, password: password, database: dbName)
                var ro = PGRestoreOptions()
                ro.noOwner = true
                ro.singleTransaction = true
                let runner = format.usesPgRestore
                    ? BackupEngine.pgRestore(tool: restore, target: target, options: ro, input: file)
                    : BackupEngine.psql(tool: psql, target: target, options: ro, input: file, format: format)
                let out = LockedArray<String>()
                let outcome = try await runner.run { out.append($1) }
                XCTAssertTrue(outcome.succeeded, "\(format): " + out.values.filter { $0.contains("ERROR") || $0.contains("error") }.prefix(5).joined(separator: "\n"))

                let restored = try pgClient(database: dbName)
                let counts = "SELECT (SELECT count(*) FROM customers), (SELECT count(*) FROM order_items), (SELECT count(*) FROM analytics.events)"
                let a = try await admin.query(counts)
                let b = try await restored.query(counts)
                XCTAssertEqual(a.rows, b.rows, "\(format)")
                let audit = try await restored.query("SELECT to_regclass('public.audit_log') IS NULL")
                XCTAssertEqual(audit.rows[0][0], format == .plain ? "t" : "f", "exclude-table honoured")
                restored.close()
                try await Task.sleep(nanoseconds: 200_000_000)
            } catch {
                _ = try? await admin.query("DROP DATABASE IF EXISTS \(dbName) WITH (FORCE)")
                throw error
            }
            _ = try await admin.query("DROP DATABASE IF EXISTS \(dbName) WITH (FORCE)")
        }
    }

    func testProcessRunnerTerminate() async throws {
        let runner = ProcessRunner(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo started; sleep 30"], environment: [:])
        let lines = LockedArray<String>()
        let task = Task { try await runner.run { lines.append($1) } }
        try await Task.sleep(nanoseconds: 300_000_000)
        runner.terminate()
        let outcome = try await task.value
        XCTAssertTrue(outcome.wasTerminated)
        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(lines.values, ["started"])
    }

    func testArgumentBuilders() {
        var o = PGDumpOptions()
        o.format = .plain
        o.content = .schemaOnly
        o.schemas = ["public", "Weird\"Schema"]
        o.tables = [PGTableRef(schema: "public", name: "orders")]
        o.excludeTables = [PGTableRef(schema: "public", name: "log*")]
        o.noOwner = true
        o.clean = true
        o.compression = 12
        XCTAssertEqual(o.arguments(output: "/tmp/x.sql"), [
            "--format=p", "--verbose", "--file=/tmp/x.sql", "--schema-only", "--schema", "\"public\"", "--schema", "\"Weird\"\"Schema\"",
            "--table", "\"public\".\"orders\"", "--exclude-table", "\"public\".\"log*\"", "--no-owner", "--clean", "--if-exists", "--compress=9",
        ])
        o.format = .tar
        XCTAssertFalse(o.arguments(output: "x").contains("--clean"), "--clean only applies to plain output")
        XCTAssertFalse(o.arguments(output: "x").contains { $0.hasPrefix("--compress") }, "tar has no compression")

        var r = PGRestoreOptions()
        r.clean = true
        r.jobs = 4
        XCTAssertEqual(r.pgRestoreArguments(input: "f.dump"), ["--verbose", "--clean", "--if-exists", "--jobs=4", "--exit-on-error", "f.dump"])
        r.singleTransaction = true
        XCTAssertFalse(r.pgRestoreArguments(input: "f").contains("--jobs=4"), "single transaction excludes parallel jobs")
        XCTAssertEqual(r.psqlArguments(input: "a.sql"), ["--echo-errors", "--set=ON_ERROR_STOP=1", "--single-transaction", "--file=a.sql"])

        var c = ConnectionConfig(name: "Prod / EU", driver: .postgres, host: "db.example.com", port: 6543, user: "app", database: "shop", sslMode: .require)
        c.extraOptions = ["sslrootcert": "/certs/rds.pem", "application_name": "x"]
        let t = PGConnectionTarget(config: c, password: "s3cret")
        XCTAssertEqual(t.arguments(), ["--host", "db.example.com", "--port", "6543", "--username", "app", "--dbname=shop", "--no-password"])
        let env = t.environment(base: ["PATH": "/usr/bin", "PGHOST": "evil", "PGPASSWORD": "old"])
        XCTAssertEqual(env["PGPASSWORD"], "s3cret")
        XCTAssertEqual(env["PGSSLMODE"], "require")
        XCTAssertEqual(env["PGSSLROOTCERT"], "/certs/rds.pem")
        XCTAssertNil(env["PGHOST"])
        XCTAssertEqual(env["PATH"], "/usr/bin")

        let date = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: .current, year: 2026, month: 3, day: 4, hour: 5, minute: 6).date!
        let url = BackupNaming.defaultURL(connection: c, database: "shop", fileExtension: "dump", date: date, directory: URL(fileURLWithPath: "/b"))
        XCTAssertEqual(url.path, "/b/Prod_EU-shop-20260304-0506.dump")
        XCTAssertEqual(PGToolLocator.parseVersion("pg_dump (PostgreSQL) 17.2 (Homebrew)")?.1, 17)
        XCTAssertEqual(PGToolLocator.serverMajor(versionNum: 140015), 14)
    }

    // MARK: SQLite

    func testSQLiteBackupRestoreAndImport() async throws {
        let dir = try tempDir()
        let dbPath = dir.appendingPathComponent("app.sqlite").path
        var config = ConnectionConfig(name: "local", driver: .sqlite)
        config.filePath = dbPath
        let client = DBClient(config: config, secrets: ConnectionSecrets())
        _ = try await client.query("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, flag BOOLEAN, amount NUMERIC)")

        let url = dir.appendingPathComponent("in.csv")
        try Data("id,name,flag,amount\n1,a,true,1.5\n2,\"b,c\",no,\n3,,f,3\n".utf8).write(to: url)
        let settings = try ImportFileLoader.sniff(url)
        let preview = try ImportFileLoader.preview(url, kind: .delimited, settings: settings)
        let details = try await Introspection.make(client).tableDetails(schema: "main", name: "t")
        let plan = ImportPlan(schema: "main", table: "t", columns: ImportMapping.mapByName(preview: preview, target: details.columns))
        let report = await DataImporter.run(plan: plan, source: try ImportFileLoader.makeSource(url, kind: .delimited, settings: settings), client: client) { _ in }
        XCTAssertNil(report.failure)
        XCTAssertEqual(report.inserted, 3)
        let rows = try await client.query("SELECT id, name, flag, amount FROM t ORDER BY id")
        XCTAssertEqual(rows.rows, [["1", "a", "1", "1.5"], ["2", "b,c", "0", nil], ["3", nil, "0", "3"]])

        let backup = dir.appendingPathComponent("copy.sqlite")
        try await BackupEngine.sqliteBackup(config: config, to: backup)
        _ = try await client.query("DELETE FROM t")
        client.close()
        try await Task.sleep(nanoseconds: 100_000_000)

        let safety = try BackupEngine.sqliteRestore(from: backup, over: dbPath, safetyCopyDirectory: dir)
        XCTAssertNotNil(safety)
        let reopened = DBClient(config: config, secrets: ConnectionSecrets())
        let back = try await reopened.query("SELECT count(*) FROM t")
        XCTAssertEqual(back.rows[0][0], "3")
        reopened.close()
        XCTAssertThrowsError(try BackupEngine.sqliteRestore(from: url, over: dbPath, safetyCopyDirectory: dir), "CSV is not a SQLite file")
    }
}

final class LockedArray<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func append(_ v: T) { lock.lock(); items.append(v); lock.unlock() }
    var values: [T] { lock.lock(); defer { lock.unlock() }; return items }
}
