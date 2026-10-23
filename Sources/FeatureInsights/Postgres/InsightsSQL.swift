import Foundation
import MTPCore

/// Catalog queries behind the PostgreSQL dashboard and process list (PostgreSQL 10+).
/// Every query is read-only and works for non-superusers; restricted columns come back NULL or "<insufficient privilege>".
enum InsightsSQL {
    /// Session settings for the dashboard connection: never hang on a lock, never run long.
    static let session = "SET statement_timeout = '15s'; SET lock_timeout = '3s'; SET application_name = 'TableExtra Insights'"
    static let processListSession = "SET statement_timeout = '10s'; SET lock_timeout = '2s'; SET application_name = 'TableExtra Process List'"

    // MARK: Overview

    static let server = """
        SELECT current_setting('server_version') AS server_version,
               EXTRACT(EPOCH FROM now() - pg_postmaster_start_time())::float8 AS uptime_seconds,
               (SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'client backend') AS connections,
               (SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'client backend' AND state = 'active') AS active_connections,
               (SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'client backend' AND state LIKE 'idle in transaction%') AS idle_in_transaction,
               current_setting('max_connections')::int AS max_connections,
               current_setting('superuser_reserved_connections')::int AS reserved_connections
        """

    static let databaseSize = "SELECT pg_database_size(current_database()) AS database_bytes"

    static let databaseStats = """
        SELECT xact_commit, xact_rollback, blks_hit, blks_read, deadlocks, temp_files, temp_bytes, conflicts,
               EXTRACT(EPOCH FROM now() - stats_reset)::float8 AS stats_age_seconds
        FROM pg_stat_database
        WHERE datname = current_database()
        """

    static let tableCache = """
        SELECT sum(heap_blks_hit)::float8 AS heap_hit, sum(heap_blks_read)::float8 AS heap_read,
               sum(idx_blks_hit)::float8 AS idx_hit, sum(idx_blks_read)::float8 AS idx_read
        FROM pg_statio_user_tables
        """

    // MARK: Tables

    static func tables(limit: Int) -> String {
        """
        SELECT n.nspname AS schema_name, c.relname AS table_name, c.relkind::text AS kind,
               c.reltuples::float8 AS estimated_rows,
               pg_total_relation_size(c.oid) AS total_bytes,
               pg_relation_size(c.oid) AS table_bytes,
               pg_indexes_size(c.oid) AS index_bytes,
               COALESCE(pg_total_relation_size(NULLIF(c.reltoastrelid, 0)), 0) AS toast_bytes,
               s.n_live_tup, s.n_dead_tup, s.seq_scan, s.idx_scan, s.n_mod_since_analyze,
               EXTRACT(EPOCH FROM now() - GREATEST(s.last_vacuum, s.last_autovacuum))::float8 AS vacuum_age,
               EXTRACT(EPOCH FROM now() - GREATEST(s.last_analyze, s.last_autoanalyze))::float8 AS analyze_age,
               (s.last_autovacuum IS NOT NULL AND s.last_autovacuum >= COALESCE(s.last_vacuum, '-infinity')) AS vacuum_was_auto,
               (s.last_autoanalyze IS NOT NULL AND s.last_autoanalyze >= COALESCE(s.last_analyze, '-infinity')) AS analyze_was_auto
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        LEFT JOIN pg_stat_all_tables s ON s.relid = c.oid
        WHERE c.relkind IN ('r', 'm', 'p')
          AND n.nspname NOT IN ('pg_catalog', 'information_schema')
          AND n.nspname !~ '^pg_(toast|temp_)'
        ORDER BY pg_total_relation_size(c.oid) DESC NULLS LAST, n.nspname, c.relname
        LIMIT \(max(1, limit))
        """
    }

    // MARK: Indexes

    static let unusedIndexes = """
        SELECT s.schemaname AS schema_name, s.relname AS table_name, s.indexrelname AS index_name,
               s.idx_scan, pg_relation_size(s.indexrelid) AS index_bytes,
               pg_get_indexdef(s.indexrelid) AS definition, i.indisvalid AS is_valid
        FROM pg_stat_user_indexes s
        JOIN pg_index i ON i.indexrelid = s.indexrelid
        WHERE s.idx_scan = 0
          AND NOT i.indisprimary AND NOT i.indisunique
          AND NOT EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conindid = s.indexrelid AND k.contype IN ('p', 'u', 'x'))
          AND s.schemaname !~ '^pg_(toast|temp_)'
        ORDER BY pg_relation_size(s.indexrelid) DESC, s.schemaname, s.indexrelname
        LIMIT 100
        """

    /// Indexes sharing table, key columns, operator classes, expressions and predicate.
    static let duplicateIndexes = """
        SELECT n.nspname AS schema_name, t.relname AS table_name, ci.relname AS index_name,
               pg_relation_size(i.indexrelid) AS index_bytes, pg_get_indexdef(i.indexrelid) AS definition,
               i.indisprimary AS is_primary, i.indisunique AS is_unique,
               k.conname AS constraint_name,
               COALESCE(st.idx_scan, 0) AS idx_scan,
               g.group_key
        FROM (
            SELECT indexrelid,
                   indrelid::text || '|' || indkey::text || '|' || indclass::text || '|' || COALESCE(indexprs::text, '') || '|' || COALESCE(indpred::text, '') AS group_key,
                   count(*) OVER (PARTITION BY indrelid, indkey::text, indclass::text, COALESCE(indexprs::text, ''), COALESCE(indpred::text, '')) AS n
            FROM pg_index
        ) g
        JOIN pg_index i ON i.indexrelid = g.indexrelid
        JOIN pg_class ci ON ci.oid = i.indexrelid
        JOIN pg_class t ON t.oid = i.indrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        LEFT JOIN pg_constraint k ON k.conindid = i.indexrelid AND k.conrelid = i.indrelid AND k.contype IN ('p', 'u', 'x')
        LEFT JOIN pg_stat_all_indexes st ON st.indexrelid = i.indexrelid
        WHERE g.n > 1
          AND n.nspname NOT IN ('pg_catalog', 'information_schema')
          AND n.nspname !~ '^pg_(toast|temp_)'
        ORDER BY n.nspname, t.relname, g.group_key, i.indisprimary DESC, i.indisunique DESC,
                 (k.conname IS NOT NULL) DESC, COALESCE(st.idx_scan, 0) DESC, ci.relname
        """

    static let largestIndexes = """
        SELECT s.schemaname AS schema_name, s.relname AS table_name, s.indexrelname AS index_name,
               pg_relation_size(s.indexrelid) AS index_bytes, s.idx_scan, s.idx_tup_read,
               pg_get_indexdef(s.indexrelid) AS definition, i.indisprimary AS is_primary, i.indisunique AS is_unique,
               i.indisvalid AS is_valid
        FROM pg_stat_user_indexes s
        JOIN pg_index i ON i.indexrelid = s.indexrelid
        WHERE s.schemaname !~ '^pg_(toast|temp_)'
        ORDER BY pg_relation_size(s.indexrelid) DESC
        LIMIT 25
        """

    // MARK: pg_stat_statements

    static let statementsStatus = """
        SELECT (SELECT n.nspname FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace WHERE e.extname = 'pg_stat_statements') AS installed_schema,
               (SELECT extversion FROM pg_extension WHERE extname = 'pg_stat_statements') AS installed_version,
               EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_stat_statements') AS available,
               (SELECT setting FROM pg_settings WHERE name = 'shared_preload_libraries') AS preload,
               pg_has_role(current_user, 'pg_read_all_stats', 'USAGE') AS can_read_all_stats
        """

    static let statementsColumns = """
        SELECT a.attname FROM pg_attribute a
        WHERE a.attrelid = to_regclass(format('%I.pg_stat_statements', $1::text)) AND a.attnum > 0 AND NOT a.attisdropped
        """

    enum StatementOrder: String, CaseIterable, Sendable {
        case totalTime = "total_ms"
        case meanTime = "mean_ms"
    }

    /// PostgreSQL 13 renamed total_time/mean_time/max_time to *_exec_time.
    static func topStatements(schema: String, execTimeColumns: Bool, order: StatementOrder, limit: Int = 25) -> String {
        let p = execTimeColumns ? "_exec_time" : "_time"
        let source = SQLDialect(kind: .postgres).quoteIdent(schema) + ".pg_stat_statements"
        return """
            SELECT s.queryid::text AS query_id, s.query, s.calls,
                   s.total\(p)::float8 AS total_ms, s.mean\(p)::float8 AS mean_ms, s.max\(p)::float8 AS max_ms,
                   s.rows, s.shared_blks_hit, s.shared_blks_read, s.temp_blks_written, r.rolname AS user_name,
                   (100 * s.total\(p) / NULLIF(sum(s.total\(p)) OVER (), 0))::float8 AS pct_total
            FROM \(source) s
            LEFT JOIN pg_roles r ON r.oid = s.userid
            WHERE s.dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
            ORDER BY \(order.rawValue) DESC NULLS LAST
            LIMIT \(max(1, limit))
            """
    }

    // MARK: Activity

    static let blocking = """
        SELECT blocked.pid AS blocked_pid, blocked.usename AS blocked_user, blocked.application_name AS blocked_app,
               blocked.query AS blocked_query, blocked.wait_event_type, blocked.wait_event,
               EXTRACT(EPOCH FROM now() - blocked.query_start)::float8 AS blocked_seconds,
               b.pid AS blocking_pid, blocking.usename AS blocking_user, blocking.application_name AS blocking_app,
               blocking.state AS blocking_state, blocking.query AS blocking_query,
               EXTRACT(EPOCH FROM now() - blocking.xact_start)::float8 AS blocking_xact_seconds
        FROM pg_stat_activity blocked
        CROSS JOIN LATERAL unnest(pg_blocking_pids(blocked.pid)) AS b(pid)
        LEFT JOIN pg_stat_activity blocking ON blocking.pid = b.pid
        WHERE blocked.wait_event_type = 'Lock'
        ORDER BY blocked.query_start NULLS LAST, b.pid
        LIMIT 200
        """

    /// Transactions open for more than `minSeconds`, and every idle-in-transaction session.
    static func longTransactions(minSeconds: Int = 60) -> String {
        """
        SELECT pid, datname, usename, application_name, host(client_addr) AS client_addr, backend_type, state,
               wait_event_type, wait_event,
               EXTRACT(EPOCH FROM now() - xact_start)::float8 AS xact_seconds,
               EXTRACT(EPOCH FROM now() - state_change)::float8 AS state_seconds,
               backend_xmin::text AS backend_xmin, query
        FROM pg_stat_activity
        WHERE pid <> pg_backend_pid()
          AND xact_start IS NOT NULL
          AND (state LIKE 'idle in transaction%' OR now() - xact_start > make_interval(secs => \(max(0, minSeconds))))
        ORDER BY xact_start
        LIMIT 200
        """
    }

    static let activity = """
        SELECT pid, datname, usename, application_name, host(client_addr) AS client_addr, client_hostname, client_port,
               backend_type, state, wait_event_type, wait_event,
               EXTRACT(EPOCH FROM now() - backend_start)::float8 AS backend_seconds,
               EXTRACT(EPOCH FROM now() - xact_start)::float8 AS xact_seconds,
               EXTRACT(EPOCH FROM now() - query_start)::float8 AS query_seconds,
               EXTRACT(EPOCH FROM now() - state_change)::float8 AS state_seconds,
               pid = pg_backend_pid() AS is_self,
               CASE WHEN wait_event_type = 'Lock' THEN array_to_string(pg_blocking_pids(pid), ',') END AS blocked_by,
               backend_xid::text AS backend_xid, backend_xmin::text AS backend_xmin,
               query
        FROM pg_stat_activity
        ORDER BY pid
        """

    // MARK: Maintenance

    /// Sequences above `$1` (fraction 0…1) of their range; the owning integer/smallint column caps the range.
    static let sequences = """
        WITH seqs AS (
            SELECT s.schemaname AS schema_name, s.sequencename AS sequence_name, s.data_type::text AS data_type,
                   s.last_value::numeric AS last_value, s.max_value::numeric AS max_value, s.min_value::numeric AS min_value,
                   s.increment_by, s.cycle,
                   col.table_schema, col.table_name, col.column_name, col.column_type,
                   CASE col.column_type WHEN 'smallint' THEN 32767::numeric WHEN 'integer' THEN 2147483647::numeric END AS column_max
            FROM pg_sequences s
            LEFT JOIN LATERAL (
                SELECT tn.nspname AS table_schema, t.relname AS table_name, a.attname AS column_name,
                       format_type(a.atttypid, NULL) AS column_type
                FROM pg_class sc
                JOIN pg_namespace sn ON sn.oid = sc.relnamespace
                JOIN pg_depend d ON d.objid = sc.oid AND d.classid = 'pg_class'::regclass
                                AND d.refclassid = 'pg_class'::regclass AND d.deptype IN ('a', 'i')
                JOIN pg_class t ON t.oid = d.refobjid
                JOIN pg_namespace tn ON tn.oid = t.relnamespace
                JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = d.refobjsubid
                WHERE sn.nspname = s.schemaname AND sc.relname = s.sequencename
                LIMIT 1
            ) col ON true
            WHERE s.increment_by > 0
        ), usage AS (
            SELECT *, LEAST(max_value, COALESCE(column_max, max_value)) AS effective_max,
                   ((last_value - min_value) / NULLIF(LEAST(max_value, COALESCE(column_max, max_value)) - min_value, 0))::float8 AS used_fraction
            FROM seqs
        )
        SELECT schema_name, sequence_name, data_type, last_value::text AS last_value, effective_max::text AS effective_max,
               max_value::text AS max_value, cycle, table_schema, table_name, column_name, column_type, used_fraction
        FROM usage
        WHERE used_fraction > $1::float8
        ORDER BY used_fraction DESC
        LIMIT 100
        """

    static let vacuum = """
        SELECT s.schemaname AS schema_name, s.relname AS table_name, s.n_live_tup, s.n_dead_tup, s.n_mod_since_analyze,
               (100.0 * s.n_dead_tup / NULLIF(s.n_live_tup + s.n_dead_tup, 0))::float8 AS dead_pct,
               (current_setting('autovacuum_vacuum_threshold')::float8
                 + current_setting('autovacuum_vacuum_scale_factor')::float8 * GREATEST(c.reltuples, 0))::float8 AS autovacuum_threshold,
               EXTRACT(EPOCH FROM now() - GREATEST(s.last_vacuum, s.last_autovacuum))::float8 AS vacuum_age,
               EXTRACT(EPOCH FROM now() - GREATEST(s.last_analyze, s.last_autoanalyze))::float8 AS analyze_age,
               (s.last_analyze IS NULL AND s.last_autoanalyze IS NULL) AS never_analyzed,
               c.reloptions::text AS reloptions
        FROM pg_stat_user_tables s
        JOIN pg_class c ON c.oid = s.relid
        WHERE (s.last_analyze IS NULL AND s.last_autoanalyze IS NULL)
           OR s.n_dead_tup > current_setting('autovacuum_vacuum_threshold')::float8
                + current_setting('autovacuum_vacuum_scale_factor')::float8 * GREATEST(c.reltuples, 0)
           OR (s.n_dead_tup >= 1000 AND s.n_dead_tup > 0.2 * GREATEST(s.n_live_tup, 1))
        ORDER BY s.n_dead_tup DESC, s.schemaname, s.relname
        LIMIT 100
        """

    /// Transaction ID age per database (wraparound protection).
    static let xidAge = """
        SELECT datname, age(datfrozenxid)::float8 AS xid_age,
               current_setting('autovacuum_freeze_max_age')::float8 AS freeze_max_age
        FROM pg_database
        WHERE datallowconn
        ORDER BY age(datfrozenxid) DESC
        """
}

/// Suggested fixes; they are only ever opened in a query tab, never executed by the dashboard.
public enum InsightsFix {
    private static let d = SQLDialect(kind: .postgres)

    static func name(_ schema: String, _ name: String) -> String {
        d.quoteIdentIfNeeded(schema) + "." + d.quoteIdentIfNeeded(name)
    }

    public static func dropIndex(schema: String, name: String) -> String {
        """
        -- DROP INDEX CONCURRENTLY cannot run inside a transaction block.
        DROP INDEX CONCURRENTLY IF EXISTS \(self.name(schema, name));
        """
    }

    public static func dropConstraint(schema: String, table: String, constraint: String) -> String {
        """
        -- The index backs a constraint; foreign keys may depend on it.
        ALTER TABLE \(name(schema, table)) DROP CONSTRAINT \(d.quoteIdentIfNeeded(constraint));
        """
    }

    public static func vacuumAnalyze(schema: String, table: String) -> String {
        "VACUUM (ANALYZE, VERBOSE) \(name(schema, table));"
    }

    public static func analyze(schema: String, table: String) -> String {
        "ANALYZE VERBOSE \(name(schema, table));"
    }

    public static func cancelBackend(pid: Int) -> String { "SELECT pg_cancel_backend(\(pid));" }

    public static func terminateBackend(pid: Int) -> String { "SELECT pg_terminate_backend(\(pid));" }

    public static func widenSequence(schema: String, sequence: String, table: String?, tableSchema: String?, column: String?, columnType: String?) -> String {
        var lines = ["-- Widen the sequence and, when needed, its column. ALTER COLUMN … TYPE bigint rewrites the table under an exclusive lock."]
        if let table, let column, let columnType, columnType != "bigint" {
            lines.append("ALTER TABLE \(name(tableSchema ?? schema, table)) ALTER COLUMN \(d.quoteIdentIfNeeded(column)) TYPE bigint;")
        }
        lines.append("ALTER SEQUENCE \(name(schema, sequence)) AS bigint MAXVALUE 9223372036854775807;")
        return lines.joined(separator: "\n")
    }

    public static let createPgStatStatements = """
        -- pg_stat_statements must also be listed in shared_preload_libraries (server restart required).
        CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
        """

    public static let resetPgStatStatements = "SELECT pg_stat_statements_reset();"

    public static func idleInTransactionTimeout(database: String) -> String {
        """
        -- Ends sessions that stay idle inside a transaction (applies to new sessions of this database).
        ALTER DATABASE \(d.quoteIdentIfNeeded(database)) SET idle_in_transaction_session_timeout = '10min';
        """
    }
}
