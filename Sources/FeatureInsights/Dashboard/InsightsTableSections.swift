import MTPCore
import MTPUIKit
import SwiftUI

/// Table height for `rows` rows, capped so the dashboard stays scrollable.
func tableHeight(rows: Int, max cap: Int = 12) -> CGFloat {
    CGFloat(min(max(rows, 3), cap)) * 24 + 32
}

// MARK: Tables

extension TableStat {
    var sortRows: Double { estimatedRows ?? -1 }
    var sortDead: Double { deadRatio ?? -1 }
    var sortVacuum: Double { vacuumAgeSeconds ?? .greatestFiniteMagnitude }
    var sortAnalyze: Double { analyzeAgeSeconds ?? .greatestFiniteMagnitude }
    var sortSeq: Int64 { seqScans ?? -1 }
    var sortIdx: Int64 { indexScans ?? -1 }
    var kindLabel: String? { kind == "m" ? "matview" : kind == "p" ? "partitioned" : nil }
}

struct TablesSection: View {
    @ObservedObject var model: InsightsDashboardModel
    @State private var sortOrder: [KeyPathComparator<TableStat>] = [KeyPathComparator(\TableStat.totalBytes, order: .reverse)]
    @State private var selection: TableStat.ID?

    var body: some View {
        InsightsCard(title: "Tables", systemImage: "tablecells",
                     subtitle: "Largest tables. Sizes include TOAST; dead tuples and scans come from pg_stat_all_tables since the last statistics reset.",
                     badge: model.tables.value.map { "\($0.count)" }, isLoading: model.tables.isLoading) {
            SectionBody(state: model.tables, user: model.connectionUser, open: model.openFix) { tables in
                if tables.isEmpty {
                    EmptyFinding(text: "No user tables.", systemImage: "tray", tone: .neutral)
                } else {
                    table(tables.sorted(using: sortOrder))
                        .frame(height: tableHeight(rows: tables.count, max: 14))
                    if let t = tables.first(where: { $0.id == selection }) { detail(t) }
                }
            }
        }
    }

    /// Share of the whole database (overview size), which drives the bar tint.
    func databaseShare(_ t: TableStat) -> Double? {
        guard let db = model.overview.value?.databaseBytes, db > 0 else { return nil }
        return Double(t.totalBytes) / Double(db)
    }

    func table(_ rows: [TableStat]) -> some View {
        // Size bars are scaled to the largest table.
        let largest = rows.map(\.totalBytes).max() ?? 0
        return Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Table", value: \TableStat.id) { (t: TableStat) in
                HStack(spacing: 4) {
                    Text(t.id).lineLimit(1)
                    if let k = t.kindLabel { Tag(k, tone: .neutral) }
                }
            }
            .width(min: 140, ideal: 220)
            TableColumn("Est. rows", value: \TableStat.sortRows) { (t: TableStat) in
                Text(InsightsFormat.compact(t.estimatedRows)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 80)
            TableColumn("Total", value: \TableStat.totalBytes) { (t: TableStat) in
                HeatBarCell(text: InsightsFormat.bytes(t.totalBytes), fraction: largest > 0 ? Double(t.totalBytes) / Double(largest) : 0,
                            tone: HeatBarCell.tone(databaseShare(t), warning: 0.25, critical: 0.5))
                    .help(databaseShare(t).map { "\(InsightsFormat.percent($0)) of the database size" } ?? InsightsFormat.bytes(t.totalBytes))
            }
            .width(min: 70, ideal: 95)
            TableColumn("Heap", value: \TableStat.tableBytes) { (t: TableStat) in
                Text(InsightsFormat.bytes(t.tableBytes)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 75)
            TableColumn("Indexes", value: \TableStat.indexBytes) { (t: TableStat) in
                Text(InsightsFormat.bytes(t.indexBytes)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 75)
            TableColumn("TOAST", value: \TableStat.toastBytes) { (t: TableStat) in
                Text(InsightsFormat.bytes(t.toastBytes)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 50, ideal: 70)
            Group {
                TableColumn("Dead", value: \TableStat.sortDead) { (t: TableStat) in
                    Text(InsightsFormat.percent(t.deadRatio))
                        .monospacedDigit()
                        .foregroundStyle((t.deadRatio ?? 0) > 0.2 ? Color.orange : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 45, ideal: 55)
                TableColumn("Vacuumed", value: \TableStat.sortVacuum) { (t: TableStat) in
                    Text(InsightsFormat.ago(t.vacuumAgeSeconds) + (t.vacuumAgeSeconds != nil && t.vacuumWasAuto ? " (auto)" : ""))
                        .foregroundStyle(t.vacuumAgeSeconds == nil ? Color.secondary : Color.primary)
                }
                .width(min: 80, ideal: 110)
                TableColumn("Analyzed", value: \TableStat.sortAnalyze) { (t: TableStat) in
                    Text(InsightsFormat.ago(t.analyzeAgeSeconds) + (t.analyzeAgeSeconds != nil && t.analyzeWasAuto ? " (auto)" : ""))
                        .foregroundStyle(t.analyzeAgeSeconds == nil ? Color.orange : Color.primary)
                }
                .width(min: 80, ideal: 110)
                TableColumn("Seq scans", value: \TableStat.sortSeq) { (t: TableStat) in
                    Text(InsightsFormat.compact(t.seqScans.map(Double.init))).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 55, ideal: 70)
                TableColumn("Index scans", value: \TableStat.sortIdx) { (t: TableStat) in
                    Text(InsightsFormat.compact(t.indexScans.map(Double.init))).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 60, ideal: 80)
            }
        }
        .contextMenu(forSelectionType: TableStat.ID.self) { ids in
            if let id = ids.first, let t = model.tables.value?.first(where: { $0.id == id }) {
                Button("Open Table") { model.context.openTable(schema: t.schema, name: t.name) }
                Button("VACUUM (ANALYZE) in Query Tab") { model.openFix(title: "VACUUM \(t.name)", sql: InsightsFix.vacuumAnalyze(schema: t.schema, table: t.name)) }
                Button("ANALYZE in Query Tab") { model.openFix(title: "ANALYZE \(t.name)", sql: InsightsFix.analyze(schema: t.schema, table: t.name)) }
                Divider()
                Button("Copy Name") { Pasteboard.copy(t.id) }
            }
        } primaryAction: { ids in
            if let id = ids.first, let t = model.tables.value?.first(where: { $0.id == id }) {
                model.context.openTable(schema: t.schema, name: t.name)
            }
        }
    }

    func detail(_ t: TableStat) -> some View {
        HStack(spacing: 8) {
            Text(t.id).font(DS.Typo.callout.weight(.medium))
            Text("\(InsightsFormat.count(t.liveTuples)) live · \(InsightsFormat.count(t.deadTuples)) dead · \(InsightsFormat.count(t.modifiedSinceAnalyze)) modified since analyze · \(InsightsFormat.percent(t.indexScanRatio)) index scans")
                .font(DS.Typo.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Button("Open Table") { model.context.openTable(schema: t.schema, name: t.name) }.controlSize(.small)
            FixButton(title: "VACUUM \(t.name)", label: "VACUUM (ANALYZE)…", sql: InsightsFix.vacuumAnalyze(schema: t.schema, table: t.name), open: model.openFix)
        }
    }
}

// MARK: Indexes

enum IndexTab: String, CaseIterable, Identifiable {
    case unused = "Unused", duplicates = "Duplicates", largest = "Largest"
    var id: String { rawValue }
}

struct IndexesSection: View {
    @ObservedObject var model: InsightsDashboardModel
    @State var tab: IndexTab = .unused

    var body: some View {
        let report = model.indexes.value
        let findings = (report?.unused.count ?? 0) + (report?.duplicates.count ?? 0)
        InsightsCard(title: "Indexes", systemImage: "list.bullet.indent",
                     badge: report.map { _ in "\(findings)" }, badgeTone: findings > 0 ? .warning : .neutral,
                     isLoading: model.indexes.isLoading) {
            CompactSegmented(IndexTab.allCases.map { (label: label($0, report), value: $0) }, selection: $tab)
        } content: {
            SectionBody(state: model.indexes, user: model.connectionUser, open: model.openFix) { report in
                switch tab {
                case .unused: unused(report.unused)
                case .duplicates: duplicates(report.duplicates)
                case .largest: largest(report.largest)
                }
                ForEach(report.errors, id: \.self) { SectionErrorView(message: $0) }
            }
        }
    }

    func label(_ t: IndexTab, _ r: IndexReport?) -> String {
        switch t {
        case .unused: return r.map { "Unused (\($0.unused.count))" } ?? "Unused"
        case .duplicates: return r.map { "Duplicates (\($0.duplicates.count))" } ?? "Duplicates"
        case .largest: return "Largest"
        }
    }

    var statsNote: String {
        let since = model.overview.value?.statsAgeSeconds.map { "the last statistics reset (\(InsightsFormat.ago($0)))" }
            ?? "statistics collection began"
        return "Scans are counted on this server since \(since). Read replicas keep their own counters: check them before dropping."
    }

    @ViewBuilder
    func unused(_ items: [IndexStat]) -> some View {
        Text("Non-unique indexes never scanned. \(statsNote)").font(DS.Typo.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if items.isEmpty {
            EmptyFinding(text: "Every non-unique index has been used.")
        } else {
            VStack(spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, ix in
                    FindingRow(index: i, highlight: ix.isValid ? nil : .critical) {
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text("\(ix.schema).\(ix.name)").font(DS.Typo.callout.weight(.medium))
                                    if !ix.isValid { Tag("INVALID", tone: .critical) }
                                    Text("on \(ix.table)").font(DS.Typo.callout).foregroundStyle(.secondary)
                                }
                                SQLSnippet(text: ix.definition, lineLimit: 2)
                            }
                            Spacer()
                            Text(InsightsFormat.bytes(ix.bytes)).font(DS.Typo.callout).monospacedDigit()
                            FixButton(title: "Drop \(ix.name)", sql: InsightsFix.dropIndex(schema: ix.schema, name: ix.name), open: model.openFix)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    func duplicates(_ groups: [DuplicateIndexGroup]) -> some View {
        Text("Indexes with the same table, key columns, operator classes and predicate. Keep one, drop the rest.")
            .font(DS.Typo.caption).foregroundStyle(.secondary)
        if groups.isEmpty {
            EmptyFinding(text: "No duplicate indexes.")
        } else {
            VStack(spacing: 4) {
                ForEach(Array(groups.enumerated()), id: \.element.id) { i, g in
                    FindingRow(index: i) {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text("\(g.schema).\(g.table)").font(DS.Typo.callout.weight(.medium))
                                Text("\(InsightsFormat.bytes(g.wastedBytes)) redundant").font(DS.Typo.caption).foregroundStyle(.secondary)
                            }
                            ForEach(g.indexes) { ix in
                                HStack(spacing: 6) {
                                    Image(systemName: ix == g.keep ? "checkmark.circle.fill" : "minus.circle")
                                        .foregroundStyle(ix == g.keep ? Color.green : Color.orange)
                                    Text(ix.name).font(DS.Typo.callout)
                                    if ix.isPrimary { Tag("PRIMARY", tone: .info) } else if ix.isUnique { Tag("UNIQUE", tone: .info) }
                                    Text("\(InsightsFormat.bytes(ix.bytes)) · \(InsightsFormat.compact(ix.scans.map(Double.init))) scans")
                                        .font(DS.Typo.caption).monospacedDigit().foregroundStyle(.secondary)
                                    SQLSnippet(text: ix.definition, lineLimit: 1)
                                    if ix != g.keep { dropButton(ix) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    func dropButton(_ ix: IndexStat) -> some View {
        if let constraint = ix.constraintName {
            FixButton(title: "Drop \(constraint)", label: "Drop Constraint…",
                      sql: InsightsFix.dropConstraint(schema: ix.schema, table: ix.table, constraint: constraint), open: model.openFix)
        } else {
            FixButton(title: "Drop \(ix.name)", label: "Drop Index…", sql: InsightsFix.dropIndex(schema: ix.schema, name: ix.name), open: model.openFix)
        }
    }

    @ViewBuilder
    func largest(_ items: [IndexStat]) -> some View {
        if items.isEmpty {
            EmptyFinding(text: "No user indexes.", systemImage: "tray", tone: .neutral)
        } else {
            let top = Double(items.first?.bytes ?? 1)
            VStack(spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, ix in
                    FindingRow(index: i) {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(ix.name).font(DS.Typo.callout.weight(.medium)).lineLimit(1)
                                    if ix.isPrimary { Tag("PRIMARY", tone: .info) } else if ix.isUnique { Tag("UNIQUE", tone: .info) }
                                    if !ix.isValid { Tag("INVALID", tone: .critical) }
                                }
                                Text("\(ix.schema).\(ix.table)").font(DS.Typo.caption).foregroundStyle(.secondary)
                            }
                            .frame(minWidth: 200, alignment: .leading)
                            Meter(fraction: top > 0 ? Double(ix.bytes) / top : 0).frame(height: 4)
                            Text(InsightsFormat.bytes(ix.bytes)).font(DS.Typo.callout).monospacedDigit().frame(width: 80, alignment: .trailing)
                            Text("\(InsightsFormat.compact(ix.scans.map(Double.init))) scans")
                                .font(DS.Typo.caption).monospacedDigit().foregroundStyle((ix.scans ?? 0) == 0 ? Color.orange : Color.secondary)
                                .frame(width: 80, alignment: .trailing)
                        }
                        .help(ix.definition)
                    }
                }
            }
        }
    }
}

// MARK: Slow queries

enum StatementTab: String, CaseIterable, Identifiable {
    case total = "By total time", mean = "By mean time"
    var id: String { rawValue }
}

struct SlowQueriesSection: View {
    @ObservedObject var model: InsightsDashboardModel
    @State private var tab: StatementTab = .total
    @State private var selection: StatementStat.ID?
    @State private var sortOrder: [KeyPathComparator<StatementStat>] = []

    init(model: InsightsDashboardModel, tab: StatementTab = .total) {
        self.model = model
        _tab = State(initialValue: tab)
    }

    var body: some View {
        let report = model.statements.value
        InsightsCard(title: "Slow queries", systemImage: "tortoise",
                     subtitle: report?.isUsable == true ? "pg_stat_statements \(report?.installedVersion ?? ""): normalized statements of this database." : nil,
                     isLoading: model.statements.isLoading) {
            if report?.isUsable == true {
                CompactSegmented(StatementTab.allCases.map { (label: $0.rawValue, value: $0) }, selection: $tab)
            }
        } content: {
            SectionBody(state: model.statements, user: model.connectionUser, open: model.openFix) { report in
                if report.isUsable {
                    let rows = tab == .total ? report.byTotalTime : report.byMeanTime
                    if rows.isEmpty {
                        EmptyFinding(text: "pg_stat_statements has no entries for this database yet.", systemImage: "tray", tone: .neutral)
                    } else {
                        table(sortOrder.isEmpty ? rows : rows.sorted(using: sortOrder))
                            .frame(height: tableHeight(rows: rows.count, max: 10))
                        if let s = rows.first(where: { $0.id == selection }) { detail(s) }
                    }
                    HStack {
                        if !report.canReadAllStats {
                            Text("Other roles' query texts are hidden: this role lacks pg_read_all_stats.")
                                .font(DS.Typo.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        FixButton(title: "Reset pg_stat_statements", label: "Reset Statistics…", sql: InsightsFix.resetPgStatStatements, open: model.openFix)
                    }
                } else {
                    StatementsSetupView(report: report, open: model.openFix)
                }
            }
        }
    }

    func table(_ rows: [StatementStat]) -> some View {
        // Bars are scaled to the largest row shown; tints follow the absolute share / duration.
        let maxShare = rows.compactMap(\.percentOfTotal).max() ?? 0
        let maxTotal = rows.map(\.totalMs).max() ?? 0
        let maxMean = rows.map(\.meanMs).max() ?? 0
        let byMean = tab == .mean
        return Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Query", value: \StatementStat.query) { (s: StatementStat) in
                HighlightedSQLLine(sql: s.query)
            }
            .width(min: 200, ideal: 340)
            TableColumn("Time consumed", value: \StatementStat.totalMs) { (s: StatementStat) in
                HeatBarCell(text: "\(InsightsFormat.percent((s.percentOfTotal ?? 0) / 100)) / \(InsightsFormat.ms(s.totalMs))",
                            fraction: maxShare > 0 ? (s.percentOfTotal ?? 0) / maxShare : (maxTotal > 0 ? s.totalMs / maxTotal : 0),
                            tone: HeatBarCell.tone(s.percentOfTotal, warning: 10, critical: 25))
                    .help("\(InsightsFormat.percent((s.percentOfTotal ?? 0) / 100)) of this database's execution time")
            }
            .width(min: 120, ideal: 150)
            TableColumn("Calls", value: \StatementStat.calls) { (s: StatementStat) in
                Text(InsightsFormat.compact(Double(s.calls))).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 50, ideal: 65)
            TableColumn("Mean", value: \StatementStat.meanMs) { (s: StatementStat) in
                if byMean {
                    HeatBarCell(text: InsightsFormat.ms(s.meanMs), fraction: maxMean > 0 ? s.meanMs / maxMean : 0,
                                tone: HeatBarCell.tone(s.meanMs, warning: 100, critical: 1000))
                } else {
                    Text(InsightsFormat.ms(s.meanMs)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .width(min: 60, ideal: 85)
            TableColumn("Max") { (s: StatementStat) in
                Text(InsightsFormat.ms(s.maxMs)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 80)
            TableColumn("Rows") { (s: StatementStat) in
                Text(InsightsFormat.compact(s.rows.map(Double.init))).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 50, ideal: 65)
            TableColumn("Cache hit") { (s: StatementStat) in
                Text(InsightsFormat.percent(s.cacheHitRatio)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 55, ideal: 70)
        }
        .contextMenu(forSelectionType: StatementStat.ID.self) { ids in
            if let id = ids.first, let s = allRows.first(where: { $0.id == id }) {
                Button("Open in Query Tab") { model.openFix(title: "Slow query", sql: queryTabSQL(s)) }
                Button("Copy Query") { Pasteboard.copy(s.query) }
            }
        }
    }

    var allRows: [StatementStat] { (model.statements.value?.byTotalTime ?? []) + (model.statements.value?.byMeanTime ?? []) }

    func queryTabSQL(_ s: StatementStat) -> String {
        "-- From pg_stat_statements: replace $1, $2… with real values before running or explaining.\n" + s.query
    }

    func detail(_ s: StatementStat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("\(InsightsFormat.count(s.calls)) calls · total \(InsightsFormat.ms(s.totalMs)) · mean \(InsightsFormat.ms(s.meanMs)) · max \(InsightsFormat.ms(s.maxMs)) · \(InsightsFormat.count(s.rows)) rows")
                    .font(DS.Typo.caption).monospacedDigit().foregroundStyle(.secondary)
                if let user = s.user { Tag(user, tone: .neutral, uppercase: false) }
                Spacer()
                Button("Copy") { Pasteboard.copy(s.query) }.controlSize(.small)
                FixButton(title: "Slow query", sql: queryTabSQL(s), open: model.openFix)
            }
            SQLSnippet(text: s.query, lineLimit: 8)
                .padding(DS.Space.m)
                .background(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).fill(DS.Palette.canvas))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).strokeBorder(DS.Palette.separator.opacity(0.7), lineWidth: 0.5))
        }
    }
}

/// Shown when pg_stat_statements is missing or not preloaded.
struct StatementsSetupView: View {
    var report: StatementsReport
    var open: (String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            Banner(.info, headline)
            if let error = report.queryError {
                Text(error).font(DS.Typo.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack(spacing: DS.Space.xl) {
                status("Available on server", report.availableOnServer)
                status("In shared_preload_libraries", report.isPreloaded)
                status("Extension created", report.isInstalled)
            }
            .font(DS.Typo.caption)
            HStack(alignment: .top, spacing: DS.Space.xxl) {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    guideTitle("Amazon RDS / Aurora")
                    step(1, "In the DB parameter group, add pg_stat_statements to shared_preload_libraries (optionally set pg_stat_statements.track = all).")
                    step(2, "Reboot the instance: shared_preload_libraries is a static parameter.")
                    step(3, "Run CREATE EXTENSION pg_stat_statements; in this database as rds_superuser.")
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    guideTitle("Self-managed")
                    step(1, "In postgresql.conf: shared_preload_libraries = 'pg_stat_statements', then restart the server.")
                    step(2, "Run CREATE EXTENSION pg_stat_statements; in this database.")
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            FixButton(title: "Enable pg_stat_statements", label: "Open CREATE EXTENSION in Query Tab",
                      sql: InsightsFix.createPgStatStatements, open: open)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func guideTitle(_ text: String) -> some View {
        Text(text.uppercased()).font(DS.Typo.eyebrow).tracking(0.6).foregroundStyle(.secondary).padding(.bottom, DS.Space.xxs)
    }

    var headline: String {
        if !report.isInstalled { return "pg_stat_statements is not installed in this database. It records execution statistics of every statement." }
        return "pg_stat_statements is installed but cannot be read: it must be loaded through shared_preload_libraries."
    }

    func status(_ title: String, _ value: Bool?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: value == true ? "checkmark.circle.fill" : value == false ? "xmark.circle" : "questionmark.circle")
                .foregroundStyle(value == true ? Color.green : value == false ? Color.orange : Color.secondary)
            Text(title + (value == nil ? " (hidden from this role)" : "")).foregroundStyle(.secondary)
        }
    }

    func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(n)").font(DS.Typo.micro.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.primary.opacity(0.06)))
            Text(text).font(DS.Typo.caption).fixedSize(horizontal: false, vertical: true)
        }
    }
}
