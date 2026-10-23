import Foundation

// Value types behind the PostgreSQL dashboard. Sizes are bytes, durations seconds, nil = unknown / no access.

public struct OverviewStats: Sendable, Hashable {
    public var serverVersion: String?
    public var uptimeSeconds: Double?
    public var databaseBytes: Int64?
    public var connections: Int64?
    public var activeConnections: Int64?
    public var idleInTransaction: Int64?
    public var maxConnections: Int64?
    public var reservedConnections: Int64?
    public var commits: Int64?
    public var rollbacks: Int64?
    public var blocksHit: Int64?
    public var blocksRead: Int64?
    public var deadlocks: Int64?
    public var tempFiles: Int64?
    public var tempBytes: Int64?
    public var conflicts: Int64?
    /// Seconds since pg_stat_database was last reset (nil when never reset).
    public var statsAgeSeconds: Double?
    public var tableHitRatio: Double?
    public var indexHitRatio: Double?
    /// Partial failures ("Database size: permission denied").
    public var errors: [String] = []

    public var cacheHitRatio: Double? {
        guard let h = blocksHit, let r = blocksRead, h + r > 0 else { return nil }
        return Double(h) / Double(h + r)
    }

    public var rollbackRatio: Double? {
        guard let c = commits, let r = rollbacks, c + r > 0 else { return nil }
        return Double(r) / Double(c + r)
    }

    public var connectionUsage: Double? {
        guard let c = connections, let m = maxConnections, m > 0 else { return nil }
        return Double(c) / Double(m)
    }
}

public struct TableStat: Identifiable, Sendable, Hashable {
    public var schema: String
    public var name: String
    /// "r" table, "m" materialized view, "p" partitioned table.
    public var kind: String
    public var estimatedRows: Double?
    public var totalBytes: Int64
    public var tableBytes: Int64
    public var indexBytes: Int64
    public var toastBytes: Int64
    public var liveTuples: Int64?
    public var deadTuples: Int64?
    public var seqScans: Int64?
    public var indexScans: Int64?
    public var modifiedSinceAnalyze: Int64?
    public var vacuumAgeSeconds: Double?
    public var analyzeAgeSeconds: Double?
    public var vacuumWasAuto: Bool
    public var analyzeWasAuto: Bool

    public var id: String { "\(schema).\(name)" }

    public var deadRatio: Double? {
        guard let live = liveTuples, let dead = deadTuples, live + dead > 0 else { return nil }
        return Double(dead) / Double(live + dead)
    }

    /// Share of scans that were index scans.
    public var indexScanRatio: Double? {
        let s = seqScans ?? 0, i = indexScans ?? 0
        guard s + i > 0 else { return nil }
        return Double(i) / Double(s + i)
    }
}

public struct IndexStat: Identifiable, Sendable, Hashable {
    public var schema: String
    public var table: String
    public var name: String
    public var bytes: Int64
    public var scans: Int64?
    public var tuplesRead: Int64?
    public var definition: String
    public var isPrimary: Bool
    public var isUnique: Bool
    public var isValid: Bool
    /// Constraint backed by this index (duplicates only).
    public var constraintName: String?

    public var id: String { "\(schema).\(name)" }
}

public struct DuplicateIndexGroup: Identifiable, Sendable, Hashable {
    public var id: String
    public var schema: String
    public var table: String
    /// First entry is the one to keep (primary / unique / constraint / most used).
    public var indexes: [IndexStat]

    public var keep: IndexStat? { indexes.first }
    public var redundant: [IndexStat] { Array(indexes.dropFirst()) }
    public var wastedBytes: Int64 { redundant.reduce(0) { $0 + $1.bytes } }
}

public struct IndexReport: Sendable, Hashable {
    public var unused: [IndexStat]
    public var duplicates: [DuplicateIndexGroup]
    public var largest: [IndexStat]
    public var errors: [String] = []
}

public struct StatementStat: Identifiable, Sendable, Hashable {
    public var id: String
    public var query: String
    public var calls: Int64
    public var totalMs: Double
    public var meanMs: Double
    public var maxMs: Double?
    public var rows: Int64?
    public var sharedHit: Int64?
    public var sharedRead: Int64?
    public var tempWritten: Int64?
    public var user: String?
    /// Share (0…100) of the database's total execution time.
    public var percentOfTotal: Double?

    public var cacheHitRatio: Double? {
        let h = sharedHit ?? 0, r = sharedRead ?? 0
        guard h + r > 0 else { return nil }
        return Double(h) / Double(h + r)
    }
}

public struct StatementsReport: Sendable, Hashable {
    /// Schema holding the extension when it is installed.
    public var installedSchema: String?
    public var installedVersion: String?
    public var availableOnServer: Bool
    /// nil when the setting is hidden from this role.
    public var preloadLibraries: String?
    public var canReadAllStats: Bool
    public var byTotalTime: [StatementStat] = []
    public var byMeanTime: [StatementStat] = []
    /// Set when the extension exists but cannot be queried (usually not preloaded).
    public var queryError: String?

    public var isInstalled: Bool { installedSchema != nil }
    public var isPreloaded: Bool? {
        preloadLibraries.map { $0.split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == "pg_stat_statements" } }
    }
    public var isUsable: Bool { isInstalled && queryError == nil }
}

public struct BlockingPair: Identifiable, Sendable, Hashable {
    public var blockedPID: Int
    public var blockedUser: String?
    public var blockedApplication: String?
    public var blockedQuery: String?
    public var waitEventType: String?
    public var waitEvent: String?
    public var blockedSeconds: Double?
    /// 0 for a prepared transaction.
    public var blockingPID: Int
    public var blockingUser: String?
    public var blockingApplication: String?
    public var blockingState: String?
    public var blockingQuery: String?
    public var blockingTransactionSeconds: Double?

    public var id: String { "\(blockedPID)-\(blockingPID)" }
}

public struct LongTransaction: Identifiable, Sendable, Hashable {
    public var pid: Int
    public var database: String?
    public var user: String?
    public var application: String?
    public var clientAddress: String?
    public var backendType: String?
    public var state: String?
    public var waitEventType: String?
    public var waitEvent: String?
    public var transactionSeconds: Double?
    public var stateSeconds: Double?
    public var backendXmin: String?
    public var query: String?

    public var id: Int { pid }
    public var isIdleInTransaction: Bool { state?.hasPrefix("idle in transaction") ?? false }
}

public struct SequenceUsage: Identifiable, Sendable, Hashable {
    public var schema: String
    public var name: String
    public var dataType: String
    public var lastValue: String?
    public var effectiveMax: String?
    public var maxValue: String?
    public var cycles: Bool
    public var tableSchema: String?
    public var table: String?
    public var column: String?
    public var columnType: String?
    /// 0…1 of the range between min_value and the effective max.
    public var usedFraction: Double

    public var id: String { "\(schema).\(name)" }
    /// The owning column is narrower than the sequence (int column fed by a bigint sequence).
    public var limitedByColumn: Bool {
        guard let columnType else { return false }
        return (columnType == "integer" || columnType == "smallint") && dataType == "bigint"
    }
}

public struct VacuumIssue: Identifiable, Sendable, Hashable {
    public var schema: String
    public var table: String
    public var liveTuples: Int64?
    public var deadTuples: Int64?
    public var modifiedSinceAnalyze: Int64?
    public var deadPercent: Double?
    public var autovacuumThreshold: Double?
    public var vacuumAgeSeconds: Double?
    public var analyzeAgeSeconds: Double?
    public var neverAnalyzed: Bool
    public var reloptions: String?

    public var id: String { "\(schema).\(table)" }
    public var aboveAutovacuumThreshold: Bool {
        guard let dead = deadTuples, let t = autovacuumThreshold else { return false }
        return Double(dead) > t
    }
    public var needsVacuum: Bool { aboveAutovacuumThreshold || (deadTuples ?? 0) >= 1000 }
}

public struct XIDAge: Identifiable, Sendable, Hashable {
    public var database: String
    public var age: Double
    public var freezeMaxAge: Double

    public var id: String { database }
    /// Fraction of the 2^31 wraparound horizon.
    public var wraparoundFraction: Double { age / 2_147_483_648 }
}

public struct VacuumReport: Sendable, Hashable {
    public var issues: [VacuumIssue]
    public var xidAges: [XIDAge]
    public var errors: [String] = []
}
