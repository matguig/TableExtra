import Foundation
import MTPCore

/// Runs the dashboard queries on one client and maps them to models. Each call is independent.
public struct PostgresInsights: Sendable {
    public let client: DBClient

    public init(client: DBClient) { self.client = client }

    /// Timeouts and application_name for a dedicated dashboard connection.
    public func prepareSession() async throws {
        _ = try await client.query(InsightsSQL.session)
    }

    // MARK: Overview

    /// Never throws for a single failing metric; those land in `errors`.
    public func overview() async throws -> OverviewStats {
        var stats = OverviewStats()
        var failures = 0
        do {
            let r = try await client.query(InsightsSQL.server).typedRows.first
            stats.serverVersion = r?.string("server_version")
            stats.uptimeSeconds = r?.double("uptime_seconds")
            stats.connections = r?.int("connections")
            stats.activeConnections = r?.int("active_connections")
            stats.idleInTransaction = r?.int("idle_in_transaction")
            stats.maxConnections = r?.int("max_connections")
            stats.reservedConnections = r?.int("reserved_connections")
        } catch {
            failures += 1
            stats.errors.append("Server: \(error.insightsMessage)")
        }
        do {
            stats.databaseBytes = try await client.query(InsightsSQL.databaseSize).typedRows.first?.int("database_bytes")
        } catch {
            failures += 1
            stats.errors.append("Database size: \(error.insightsMessage)")
        }
        do {
            if let r = try await client.query(InsightsSQL.databaseStats).typedRows.first {
                stats.commits = r.int("xact_commit")
                stats.rollbacks = r.int("xact_rollback")
                stats.blocksHit = r.int("blks_hit")
                stats.blocksRead = r.int("blks_read")
                stats.deadlocks = r.int("deadlocks")
                stats.tempFiles = r.int("temp_files")
                stats.tempBytes = r.int("temp_bytes")
                stats.conflicts = r.int("conflicts")
                stats.statsAgeSeconds = r.double("stats_age_seconds")
            }
        } catch {
            failures += 1
            stats.errors.append("Statistics: \(error.insightsMessage)")
        }
        do {
            if let r = try await client.query(InsightsSQL.tableCache).typedRows.first {
                stats.tableHitRatio = Self.ratio(r.double("heap_hit"), r.double("heap_read"))
                stats.indexHitRatio = Self.ratio(r.double("idx_hit"), r.double("idx_read"))
            }
        } catch {
            stats.errors.append("Table cache: \(error.insightsMessage)")
        }
        if failures == 3 { throw DatabaseError(stats.errors.joined(separator: "\n")) }
        return stats
    }

    static func ratio(_ hit: Double?, _ read: Double?) -> Double? {
        guard let h = hit, let r = read, h + r > 0 else { return nil }
        return h / (h + r)
    }

    // MARK: Tables

    public func tables(limit: Int = 50) async throws -> [TableStat] {
        try await client.query(InsightsSQL.tables(limit: limit)).typedRows.map { r in
            TableStat(schema: r.text("schema_name"), name: r.text("table_name"), kind: r.text("kind"),
                      estimatedRows: r.double("estimated_rows").flatMap { $0 >= 0 ? $0 : nil },
                      totalBytes: r.int("total_bytes") ?? 0, tableBytes: r.int("table_bytes") ?? 0,
                      indexBytes: r.int("index_bytes") ?? 0, toastBytes: r.int("toast_bytes") ?? 0,
                      liveTuples: r.int("n_live_tup"), deadTuples: r.int("n_dead_tup"),
                      seqScans: r.int("seq_scan"), indexScans: r.int("idx_scan"),
                      modifiedSinceAnalyze: r.int("n_mod_since_analyze"),
                      vacuumAgeSeconds: r.double("vacuum_age"), analyzeAgeSeconds: r.double("analyze_age"),
                      vacuumWasAuto: r.flag("vacuum_was_auto"), analyzeWasAuto: r.flag("analyze_was_auto"))
        }
    }

    // MARK: Indexes

    public func unusedIndexes() async throws -> [IndexStat] {
        try await client.query(InsightsSQL.unusedIndexes).typedRows.map(Self.index)
    }

    public func duplicateIndexes() async throws -> [DuplicateIndexGroup] {
        let rows = try await client.query(InsightsSQL.duplicateIndexes).typedRows
        var groups: [DuplicateIndexGroup] = []
        for r in rows {
            let key = r.text("group_key")
            let index = Self.index(r)
            if let last = groups.indices.last, groups[last].id == key {
                groups[last].indexes.append(index)
            } else {
                groups.append(DuplicateIndexGroup(id: key, schema: index.schema, table: index.table, indexes: [index]))
            }
        }
        return groups.filter { $0.indexes.count > 1 }
    }

    public func largestIndexes() async throws -> [IndexStat] {
        try await client.query(InsightsSQL.largestIndexes).typedRows.map(Self.index)
    }

    /// The three index lists; fails only when all three fail.
    public func indexReport() async throws -> IndexReport {
        var report = IndexReport(unused: [], duplicates: [], largest: [])
        var failures: [String] = []
        do { report.unused = try await unusedIndexes() } catch { failures.append("Unused indexes: \(error.insightsMessage)") }
        do { report.duplicates = try await duplicateIndexes() } catch { failures.append("Duplicate indexes: \(error.insightsMessage)") }
        do { report.largest = try await largestIndexes() } catch { failures.append("Largest indexes: \(error.insightsMessage)") }
        if failures.count == 3 { throw DatabaseError(failures.joined(separator: "\n")) }
        report.errors = failures
        return report
    }

    static func index(_ r: ResultRow) -> IndexStat {
        IndexStat(schema: r.text("schema_name"), table: r.text("table_name"), name: r.text("index_name"),
                  bytes: r.int("index_bytes") ?? 0, scans: r.int("idx_scan"), tuplesRead: r.int("idx_tup_read"),
                  definition: r.text("definition"), isPrimary: r.flag("is_primary"), isUnique: r.flag("is_unique"),
                  isValid: r.bool("is_valid") ?? true, constraintName: r.string("constraint_name"))
    }

    // MARK: pg_stat_statements

    public func statements(limit: Int = 25) async throws -> StatementsReport {
        guard let s = try await client.query(InsightsSQL.statementsStatus).typedRows.first else {
            throw DatabaseError("pg_stat_statements status is unavailable")
        }
        var report = StatementsReport(installedSchema: s.string("installed_schema"),
                                      installedVersion: s.string("installed_version"),
                                      availableOnServer: s.flag("available"),
                                      preloadLibraries: s["preload"],
                                      canReadAllStats: s.flag("can_read_all_stats"))
        guard let schema = report.installedSchema else { return report }
        do {
            let cols = try await client.query(InsightsSQL.statementsColumns, [schema]).rows.compactMap { $0.first ?? nil }
            let exec = cols.isEmpty || cols.contains("total_exec_time")
            report.byTotalTime = try await topStatements(schema: schema, exec: exec, order: .totalTime, limit: limit)
            report.byMeanTime = try await topStatements(schema: schema, exec: exec, order: .meanTime, limit: limit)
        } catch {
            report.queryError = error.insightsMessage
        }
        return report
    }

    func topStatements(schema: String, exec: Bool, order: InsightsSQL.StatementOrder, limit: Int) async throws -> [StatementStat] {
        let sql = InsightsSQL.topStatements(schema: schema, execTimeColumns: exec, order: order, limit: limit)
        return try await client.query(sql).typedRows.enumerated().map { i, r in
            StatementStat(id: (r.string("query_id") ?? "row") + "-\(r.text("user_name"))-\(i)",
                          query: r.text("query"), calls: r.int("calls") ?? 0,
                          totalMs: r.double("total_ms") ?? 0, meanMs: r.double("mean_ms") ?? 0, maxMs: r.double("max_ms"),
                          rows: r.int("rows"), sharedHit: r.int("shared_blks_hit"), sharedRead: r.int("shared_blks_read"),
                          tempWritten: r.int("temp_blks_written"), user: r.string("user_name"),
                          percentOfTotal: r.double("pct_total"))
        }
    }

    // MARK: Activity

    public func blocking() async throws -> [BlockingPair] {
        try await client.query(InsightsSQL.blocking).typedRows.map { r in
            BlockingPair(blockedPID: Int(r.int("blocked_pid") ?? 0), blockedUser: r.string("blocked_user"),
                         blockedApplication: r.string("blocked_app"), blockedQuery: r.string("blocked_query"),
                         waitEventType: r.string("wait_event_type"), waitEvent: r.string("wait_event"),
                         blockedSeconds: r.double("blocked_seconds").map { max(0, $0) },
                         blockingPID: Int(r.int("blocking_pid") ?? 0), blockingUser: r.string("blocking_user"),
                         blockingApplication: r.string("blocking_app"), blockingState: r.string("blocking_state"),
                         blockingQuery: r.string("blocking_query"),
                         blockingTransactionSeconds: r.double("blocking_xact_seconds").map { max(0, $0) })
        }
    }

    public func longTransactions(minSeconds: Int = 60) async throws -> [LongTransaction] {
        try await client.query(InsightsSQL.longTransactions(minSeconds: minSeconds)).typedRows.map { r in
            LongTransaction(pid: Int(r.int("pid") ?? 0), database: r.string("datname"), user: r.string("usename"),
                            application: r.string("application_name"), clientAddress: r.string("client_addr"),
                            backendType: r.string("backend_type"), state: r.string("state"),
                            waitEventType: r.string("wait_event_type"), waitEvent: r.string("wait_event"),
                            transactionSeconds: r.double("xact_seconds").map { max(0, $0) },
                            stateSeconds: r.double("state_seconds").map { max(0, $0) },
                            backendXmin: r.string("backend_xmin"), query: r.string("query"))
        }
    }

    // MARK: Maintenance

    /// Sequences that used more than `threshold` (0…1) of their range.
    public func sequences(threshold: Double = 0.75) async throws -> [SequenceUsage] {
        try await client.query(InsightsSQL.sequences, [String(threshold)]).typedRows.map { r in
            SequenceUsage(schema: r.text("schema_name"), name: r.text("sequence_name"), dataType: r.text("data_type"),
                          lastValue: r.string("last_value"), effectiveMax: r.string("effective_max"), maxValue: r.string("max_value"),
                          cycles: r.flag("cycle"), tableSchema: r.string("table_schema"), table: r.string("table_name"),
                          column: r.string("column_name"), columnType: r.string("column_type"),
                          usedFraction: r.double("used_fraction") ?? 0)
        }
    }

    public func vacuumIssues() async throws -> [VacuumIssue] {
        try await client.query(InsightsSQL.vacuum).typedRows.map { r in
            VacuumIssue(schema: r.text("schema_name"), table: r.text("table_name"), liveTuples: r.int("n_live_tup"),
                        deadTuples: r.int("n_dead_tup"), modifiedSinceAnalyze: r.int("n_mod_since_analyze"),
                        deadPercent: r.double("dead_pct"), autovacuumThreshold: r.double("autovacuum_threshold"),
                        vacuumAgeSeconds: r.double("vacuum_age"), analyzeAgeSeconds: r.double("analyze_age"),
                        neverAnalyzed: r.flag("never_analyzed"), reloptions: r.string("reloptions"))
        }
    }

    public func xidAges() async throws -> [XIDAge] {
        try await client.query(InsightsSQL.xidAge).typedRows.map { r in
            XIDAge(database: r.text("datname"), age: r.double("xid_age") ?? 0, freezeMaxAge: r.double("freeze_max_age") ?? 200_000_000)
        }
    }

    public func vacuumReport() async throws -> VacuumReport {
        var report = VacuumReport(issues: [], xidAges: [])
        var failures: [String] = []
        do { report.issues = try await vacuumIssues() } catch { failures.append("Dead tuples: \(error.insightsMessage)") }
        do { report.xidAges = try await xidAges() } catch { failures.append("Transaction ID age: \(error.insightsMessage)") }
        if failures.count == 2 { throw DatabaseError(failures.joined(separator: "\n")) }
        report.errors = failures
        return report
    }
}
