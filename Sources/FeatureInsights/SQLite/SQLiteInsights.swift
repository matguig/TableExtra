import Foundation
import MTPCore
import MTPUIKit
import SwiftUI

public struct SQLiteTableInfo: Identifiable, Sendable, Hashable {
    public var name: String
    public var rows: Int64?
    /// Table plus its indexes, from the dbstat virtual table when SQLite was built with it.
    public var bytes: Int64?
    public var error: String?

    public var id: String { name }
}

public struct SQLiteStats: Sendable, Hashable {
    public var pageCount: Int64?
    public var pageSize: Int64?
    public var freelistCount: Int64?
    public var journalMode: String?
    public var autoVacuum: String?
    public var encoding: String?
    public var userVersion: Int64?
    public var hasStat1: Bool
    public var tables: [SQLiteTableInfo]

    public var databaseBytes: Int64? {
        guard let c = pageCount, let s = pageSize else { return nil }
        return c * s
    }

    public var freeBytes: Int64? {
        guard let f = freelistCount, let s = pageSize else { return nil }
        return f * s
    }

    public var freeFraction: Double? {
        guard let f = freelistCount, let c = pageCount, c > 0 else { return nil }
        return Double(f) / Double(c)
    }
}

/// PRAGMA-based health for SQLite files.
public struct SQLiteInsights: Sendable {
    public let client: DBClient

    public init(client: DBClient) { self.client = client }

    func pragma(_ name: String) async -> String? {
        guard let r = try? await client.query("PRAGMA \(name)") else { return nil }
        return r.rows.first?.first ?? nil
    }

    public func stats(countRows: Bool = true) async throws -> SQLiteStats {
        let names = try await client.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
            .rows.compactMap { $0.first ?? nil }
        let autoVacuumNames = ["0": "none", "1": "full", "2": "incremental"]
        var stats = SQLiteStats(
            pageCount: await pragma("page_count").flatMap { Int64($0) },
            pageSize: await pragma("page_size").flatMap { Int64($0) },
            freelistCount: await pragma("freelist_count").flatMap { Int64($0) },
            journalMode: await pragma("journal_mode"),
            autoVacuum: await pragma("auto_vacuum").map { autoVacuumNames[$0] ?? $0 },
            encoding: await pragma("encoding"),
            userVersion: await pragma("user_version").flatMap { Int64($0) },
            hasStat1: ((try? await client.query("SELECT 1 FROM sqlite_master WHERE name = 'sqlite_stat1'"))?.rows.isEmpty == false),
            tables: names.map { SQLiteTableInfo(name: $0) })

        // dbstat is optional; attribute index pages to their table.
        let sizeSQL = """
            SELECT m.tbl_name AS name, sum(d.pgsize) AS bytes
            FROM dbstat d JOIN sqlite_master m ON m.name = d.name
            GROUP BY m.tbl_name
            """
        if let sizes = try? await client.query(sizeSQL) {
            var byName: [String: Int64] = [:]
            for r in sizes.typedRows { if let n = r.string("name") { byName[n] = r.int("bytes") } }
            for i in stats.tables.indices { stats.tables[i].bytes = byName[stats.tables[i].name] }
        }
        if countRows {
            let d = SQLDialect(kind: .sqlite)
            for i in stats.tables.indices {
                do {
                    let r = try await client.query("SELECT count(*) FROM \(d.quoteIdent(stats.tables[i].name))")
                    stats.tables[i].rows = (r.rows.first?.first ?? nil).flatMap { Int64($0) }
                } catch {
                    stats.tables[i].error = error.insightsMessage
                }
            }
        }
        return stats
    }

    /// `PRAGMA integrity_check` (or quick_check) messages; ["ok"] when healthy.
    public func integrityCheck(quick: Bool = false) async throws -> [String] {
        try await client.query(quick ? "PRAGMA quick_check" : "PRAGMA integrity_check").rows.compactMap { $0.first ?? nil }
    }

    /// Rows violating foreign keys, as "table rowid → parent".
    public func foreignKeyCheck() async throws -> [String] {
        try await client.query("PRAGMA foreign_key_check").typedRows.map { r in
            "\(r.text("table")) rowid \(r.text("rowid")) → \(r.text("parent"))"
        }
    }
}

@MainActor
final class SQLiteInsightsModel: ObservableObject {
    let context: WorkspaceContext
    private var client: DBClient?
    @Published var stats = SectionState<SQLiteStats>()
    @Published var integrity: [String]?
    @Published var foreignKeys: [String]?
    @Published var checkError: String?
    @Published var isChecking = false

    init(context: WorkspaceContext) { self.context = context }

    private var insights: SQLiteInsights? { client.map(SQLiteInsights.init) }

    func start() {
        if client == nil { client = context.makeClient(label: "insights") }
        if stats.updatedAt == nil { Task { await refresh() } }
    }

    func stop() {
        client?.close()
        client = nil
    }

    func refresh() async {
        guard let insights else { return }
        stats.isLoading = true
        do {
            stats.value = try await insights.stats()
            stats.error = nil
        } catch {
            stats.error = error.insightsMessage
        }
        stats.isLoading = false
        stats.updatedAt = Date()
    }

    func runIntegrityCheck() async {
        guard let insights else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            integrity = try await insights.integrityCheck()
            foreignKeys = try await insights.foreignKeyCheck()
            checkError = nil
        } catch {
            checkError = error.insightsMessage
        }
    }
}

struct SQLiteInsightsContent: View {
    @ObservedObject var model: SQLiteInsightsModel

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader("Insights", subtitle: subtitle, systemImage: "stethoscope") {
                HStack(spacing: DS.Space.xs) {
                    if model.stats.isLoading { ProgressView().controlSize(.small).padding(.trailing, DS.Space.xs) }
                    ToolButton("Refresh", systemImage: "arrow.clockwise") {
                        Task { await model.refresh() }
                    }
                    .disabled(model.stats.isLoading)
                }
            }
            .help(model.context.connection.subtitle)
            ScrollView {
                SQLiteInsightsSections(model: model)
                    .padding(DS.Space.xl)
                    .frame(maxWidth: 1280)
                    .frame(maxWidth: .infinity)
            }
        }
        .background(DS.Palette.canvas)
    }

    /// The file name is already in the window toolbar; the full path is in the tooltip.
    var subtitle: String {
        var parts = ["SQLite"]
        if let s = model.stats.value { parts.append("\(InsightsFormat.bytes(s.databaseBytes)) · \(s.tables.count) table\(s.tables.count == 1 ? "" : "s")") }
        if let at = model.stats.updatedAt { parts.append("updated \(at.formatted(date: .omitted, time: .standard))") }
        return parts.joined(separator: " · ")
    }
}

struct SQLiteInsightsSections: View {
    @ObservedObject var model: SQLiteInsightsModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xxl) {
            InsightsCard(title: "File", systemImage: "doc", isLoading: model.stats.isLoading, plain: true) {
                SectionBody(state: model.stats) { s in
                    LazyVGrid(columns: StatTile.columns, alignment: .leading, spacing: DS.Space.m) {
                        StatTile(title: "Database size", value: InsightsFormat.bytes(s.databaseBytes),
                                 detail: "\(InsightsFormat.count(s.pageCount)) pages × \(InsightsFormat.bytes(s.pageSize))", systemImage: "internaldrive")
                        StatTile(title: "Free pages", value: InsightsFormat.count(s.freelistCount),
                                 detail: "\(InsightsFormat.bytes(s.freeBytes)) reclaimable (\(InsightsFormat.percent(s.freeFraction)))",
                                 systemImage: "square.dashed", tone: (s.freeFraction ?? 0) > 0.1 ? .warning : .neutral, progress: s.freeFraction)
                        StatTile(title: "Journal mode", value: (s.journalMode ?? "—").uppercased(),
                                 detail: s.journalMode == "wal" ? "Readers do not block writers" : "WAL allows concurrent readers", systemImage: "book")
                        StatTile(title: "Auto-vacuum", value: s.autoVacuum ?? "—", detail: "Encoding \(s.encoding ?? "—")", systemImage: "wind")
                        StatTile(title: "User version", value: InsightsFormat.count(s.userVersion), detail: "PRAGMA user_version", systemImage: "number")
                        StatTile(title: "Statistics", value: s.hasStat1 ? "Analyzed" : "Never analyzed",
                                 detail: "sqlite_stat1 helps the planner choose indexes", systemImage: "chart.bar",
                                 tone: s.hasStat1 ? .neutral : .warning)
                    }
                    HStack(spacing: DS.Space.m) {
                        Text("Suggested").font(DS.Typo.caption).foregroundStyle(.secondary)
                        if (s.freeFraction ?? 0) > 0.1 {
                            FixButton(title: "VACUUM", label: "VACUUM…", sql: "-- Rebuilds the file to reclaim free pages (needs free disk space).\nVACUUM;",
                                      open: open)
                        }
                        if !s.hasStat1 {
                            FixButton(title: "ANALYZE", label: "ANALYZE…", sql: "ANALYZE;", open: open)
                        }
                        FixButton(title: "PRAGMA optimize", label: "PRAGMA optimize…", sql: "PRAGMA optimize;", open: open)
                    }
                }
            }
            InsightsCard(title: "Integrity", systemImage: "checkmark.shield") {
                if model.isChecking { ProgressView().controlSize(.mini) }
                Button("Run Integrity Check") { Task { await model.runIntegrityCheck() } }
                    .controlSize(.small)
                    .disabled(model.isChecking)
            } content: {
                integrity
            }
            InsightsCard(title: "Tables", systemImage: "tablecells", badge: model.stats.value.map { "\($0.tables.count)" }) {
                SectionBody(state: model.stats) { s in tables(s) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func open(_ title: String, _ sql: String) { model.context.openQueryTab(title: title, sql: sql, run: false) }

    @ViewBuilder
    var integrity: some View {
        if let error = model.checkError {
            SectionErrorView(message: error)
        } else if let result = model.integrity {
            if result == ["ok"] {
                EmptyFinding(text: "PRAGMA integrity_check: ok")
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(result.prefix(100).enumerated()), id: \.offset) { _, line in
                        SQLSnippet(text: line, lineLimit: 2)
                    }
                }
            }
            if let fk = model.foreignKeys {
                if fk.isEmpty {
                    EmptyFinding(text: "PRAGMA foreign_key_check: no violations")
                } else {
                    Banner(.warning, "\(fk.count) foreign key violation\(fk.count == 1 ? "" : "s")")
                    ForEach(Array(fk.prefix(50).enumerated()), id: \.offset) { _, line in SQLSnippet(text: line, lineLimit: 1) }
                }
            }
        } else {
            Text("PRAGMA integrity_check reads the whole file; it can take a while on large databases.")
                .font(DS.Typo.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    func tables(_ s: SQLiteStats) -> some View {
        if s.tables.isEmpty {
            EmptyFinding(text: "No tables.", systemImage: "tray", tone: .neutral)
        } else {
            let top = Double(s.tables.compactMap(\.bytes).max() ?? 0)
            VStack(spacing: 2) {
                ForEach(Array(s.tables.enumerated()), id: \.element.id) { i, t in
                    FindingRow(index: i) {
                        HStack(spacing: 10) {
                            Text(t.name).font(DS.Typo.callout.weight(.medium)).frame(minWidth: 180, alignment: .leading).lineLimit(1)
                            if let bytes = t.bytes, top > 0 {
                                Meter(fraction: Double(bytes) / top).frame(height: 4)
                                Text(InsightsFormat.bytes(bytes)).font(DS.Typo.callout).monospacedDigit().frame(width: 80, alignment: .trailing)
                            } else {
                                Spacer()
                            }
                            if let error = t.error {
                                Text(error).font(DS.Typo.caption).foregroundStyle(Color(nsColor: NSColor.systemOrange.readableText())).lineLimit(1)
                            } else {
                                Text("\(InsightsFormat.count(t.rows)) rows").font(DS.Typo.callout).monospacedDigit().foregroundStyle(.secondary).frame(width: 110, alignment: .trailing)
                            }
                            Button("Open") { model.context.openTable(schema: "main", name: t.name) }.controlSize(.small)
                        }
                    }
                }
            }
        }
    }
}
