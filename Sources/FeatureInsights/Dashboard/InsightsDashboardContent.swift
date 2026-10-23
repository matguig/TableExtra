import MTPCore
import MTPUIKit
import SwiftUI

/// Header + scrollable sections. The public `InsightsDashboardView` owns the model.
struct InsightsDashboardContent: View {
    @ObservedObject var model: InsightsDashboardModel

    var body: some View {
        VStack(spacing: 0) {
            DashboardHeader(model: model)
            ScrollViewReader { proxy in
                ScrollView {
                    DashboardSections(model: model) { anchor in
                        withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(anchor, anchor: .top) }
                    }
                    .padding(DS.Space.xl)
                    .frame(maxWidth: 1280)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .background(DS.Palette.canvas)
    }
}

/// Connection, database and environment are already in the window toolbar: the header only carries
/// what is specific to this pane (server version, freshness) and its controls.
struct DashboardHeader: View {
    @ObservedObject var model: InsightsDashboardModel

    var body: some View {
        PaneHeader("Insights", subtitle: subtitle, systemImage: "stethoscope") {
            HStack(spacing: DS.Space.xs) {
                if model.isRefreshing { ProgressView().controlSize(.small).padding(.trailing, DS.Space.xs) }
                AskClaudeMenu(context: model.context, items: model.claudeItems)
                ToggleChip(title: "Auto-refresh", systemImage: "timer", isOn: $model.autoRefresh,
                           help: "Every 5 seconds, reload overview, locks, long transactions and slow queries. Use Refresh for every section.")
                ToolButton("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.refresh(.all) }
                }
                .disabled(model.isRefreshing)
            }
        }
    }

    var subtitle: String {
        var parts: [String] = []
        if let v = model.overview.value?.serverVersion ?? model.context.serverInfo?.version {
            parts.append("PostgreSQL \(v.split(separator: " ").first.map(String.init) ?? v)")
        }
        if let last = model.lastRefresh {
            parts.append("updated \(last.formatted(date: .omitted, time: .standard))")
        } else {
            parts.append("loading…")
        }
        return parts.joined(separator: " · ")
    }
}

/// Every section stacked; rendered without a ScrollView in snapshot tests.
struct DashboardSections: View {
    @ObservedObject var model: InsightsDashboardModel
    /// Scrolls the enclosing ScrollView to a section (headline figures).
    var scrollTo: ((DashboardAnchor) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xxl) {
            DashboardHeadline(model: model, scrollTo: scrollTo)
                .padding(.bottom, -DS.Space.xs)
            OverviewSection(model: model).id(DashboardAnchor.overview)
            BlockingSection(model: model).id(DashboardAnchor.locks)
            LongTransactionsSection(model: model).id(DashboardAnchor.longTransactions)
            SlowQueriesSection(model: model).id(DashboardAnchor.slowQueries)
            TablesSection(model: model).id(DashboardAnchor.tables)
            IndexesSection(model: model).id(DashboardAnchor.indexes)
            VacuumSection(model: model).id(DashboardAnchor.vacuum)
            SequencesSection(model: model).id(DashboardAnchor.sequences)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Overview

struct OverviewSection: View {
    @ObservedObject var model: InsightsDashboardModel

    var body: some View {
        InsightsCard(title: "Overview", systemImage: "gauge.with.dots.needle.33percent", isLoading: model.overview.isLoading, plain: true) {
            SectionBody(state: model.overview, user: model.connectionUser, open: model.openFix) { stats in
                LazyVGrid(columns: StatTile.columns, alignment: .leading, spacing: DS.Space.m) {
                    tiles(stats)
                }
                if !stats.errors.isEmpty {
                    ForEach(stats.errors, id: \.self) { SectionErrorView(message: $0) }
                }
            }
        }
    }

    @ViewBuilder
    func tiles(_ s: OverviewStats) -> some View {
        StatTile(title: "Server", value: s.serverVersion.map { "PostgreSQL \($0.split(separator: " ").first ?? "")" } ?? "—",
                 detail: s.serverVersion, systemImage: "server.rack")
        StatTile(title: "Uptime", value: InsightsFormat.duration(s.uptimeSeconds),
                 detail: s.statsAgeSeconds.map { "Statistics reset \(InsightsFormat.ago($0))" } ?? "Statistics never reset",
                 systemImage: "clock")
        StatTile(title: "Database size", value: InsightsFormat.bytes(s.databaseBytes), detail: model.databaseName,
                 systemImage: "internaldrive")
        StatTile(title: "Connections",
                 value: "\(InsightsFormat.count(s.connections)) / \(InsightsFormat.count(s.maxConnections))",
                 detail: "\(InsightsFormat.count(s.activeConnections)) active · \(InsightsFormat.count(s.idleInTransaction)) idle in transaction",
                 systemImage: "person.2", tone: connectionTone(s), progress: s.connectionUsage)
        StatTile(title: "Cache hit ratio", value: InsightsFormat.percent(s.cacheHitRatio, digits: 2),
                 detail: "Tables \(InsightsFormat.percent(s.tableHitRatio)) · indexes \(InsightsFormat.percent(s.indexHitRatio))",
                 systemImage: "memorychip", tone: cacheTone(s.cacheHitRatio))
        StatTile(title: "Commits / rollbacks",
                 value: "\(InsightsFormat.compact(s.commits.map(Double.init))) / \(InsightsFormat.compact(s.rollbacks.map(Double.init)))",
                 detail: "\(InsightsFormat.percent(s.rollbackRatio)) of transactions rolled back",
                 systemImage: "arrow.uturn.backward", tone: (s.rollbackRatio ?? 0) > 0.05 ? .warning : .neutral)
        StatTile(title: "Deadlocks", value: InsightsFormat.count(s.deadlocks),
                 detail: (s.deadlocks ?? 0) > 0 ? "Check the server log for the statements involved" : "Since statistics reset",
                 systemImage: "arrow.triangle.2.circlepath", tone: (s.deadlocks ?? 0) > 0 ? .warning : .neutral)
        StatTile(title: "Temp files", value: "\(InsightsFormat.count(s.tempFiles)) files",
                 detail: "\(InsightsFormat.bytes(s.tempBytes)) written by sorts and hashes over work_mem",
                 systemImage: "doc.on.doc", tone: (s.tempBytes ?? 0) > 1 << 30 ? .warning : .neutral)
    }

    func connectionTone(_ s: OverviewStats) -> Tone {
        guard let u = s.connectionUsage else { return .neutral }
        return u > 0.95 ? .critical : u > 0.8 ? .warning : .neutral
    }

    func cacheTone(_ ratio: Double?) -> Tone {
        guard let ratio else { return .neutral }
        return ratio < 0.95 ? .critical : ratio < 0.99 ? .warning : .good
    }
}

// MARK: Locks

struct BlockingSection: View {
    @ObservedObject var model: InsightsDashboardModel

    var body: some View {
        let pairs = model.blocking.value ?? []
        InsightsCard(title: "Locks & blocking", systemImage: "lock", badge: model.blocking.value.map { "\($0.count)" },
                     badgeTone: pairs.isEmpty ? .neutral : .critical, isLoading: model.blocking.isLoading) {
            SectionBody(state: model.blocking, user: model.connectionUser, open: model.openFix) { pairs in
                if pairs.isEmpty {
                    EmptyFinding(text: "No session is waiting on a lock.")
                } else {
                    VStack(spacing: DS.Space.xxs) {
                        ForEach(Array(pairs.enumerated()), id: \.element.id) { i, p in
                            FindingRow(index: i, highlight: .critical) { row(p) }
                        }
                    }
                }
            }
        }
    }

    func row(_ p: BlockingPair) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Tag("pid \(p.blockedPID)", tone: .warning)
                Text(who(p.blockedUser, p.blockedApplication)).font(DS.Typo.callout)
                Text("waiting \(InsightsFormat.duration(p.blockedSeconds)) on \(wait(p))")
                    .font(DS.Typo.callout).foregroundStyle(.secondary)
                Spacer()
            }
            SQLSnippet(text: InsightsFormat.oneLine(p.blockedQuery, limit: 400), lineLimit: 2)
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary)
                Text("blocked by").font(DS.Typo.caption).foregroundStyle(.secondary)
                Tag(p.blockingPID == 0 ? "prepared xact" : "pid \(p.blockingPID)", tone: .critical)
                Text(who(p.blockingUser, p.blockingApplication)).font(DS.Typo.callout)
                if let state = p.blockingState { Text(state).font(DS.Typo.callout).foregroundStyle(.secondary) }
                if let x = p.blockingTransactionSeconds {
                    Text("transaction open \(InsightsFormat.duration(x))").font(DS.Typo.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if let q = p.blockingQuery { SQLSnippet(text: InsightsFormat.oneLine(q, limit: 400), lineLimit: 2).padding(.leading, 20) }
            if p.blockingPID != 0 {
                HStack {
                    FixButton(title: "Cancel blocker \(p.blockingPID)", label: "Cancel Blocker…",
                              sql: InsightsFix.cancelBackend(pid: p.blockingPID), open: model.openFix)
                    FixButton(title: "Terminate blocker \(p.blockingPID)", label: "Terminate Blocker…",
                              sql: InsightsFix.terminateBackend(pid: p.blockingPID), open: model.openFix)
                }
            }
        }
    }

    func who(_ user: String?, _ app: String?) -> String {
        [user, app].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
    }

    func wait(_ p: BlockingPair) -> String {
        [p.waitEventType, p.waitEvent].compactMap { $0 }.joined(separator: ": ")
    }
}

// MARK: Long transactions

struct LongTransactionsSection: View {
    @ObservedObject var model: InsightsDashboardModel

    var body: some View {
        let items = model.longTransactions.value ?? []
        InsightsCard(title: "Long-running transactions", systemImage: "hourglass",
                     subtitle: "Open for more than \(model.longTransactionSeconds / 60) minute, or idle inside a transaction. They hold locks and stop VACUUM from removing dead rows.",
                     badge: model.longTransactions.value.map { "\($0.count)" },
                     badgeTone: items.isEmpty ? .neutral : .warning, isLoading: model.longTransactions.isLoading) {
            SectionBody(state: model.longTransactions, user: model.connectionUser, open: model.openFix) { items in
                if items.isEmpty {
                    EmptyFinding(text: "No long-running or idle-in-transaction session.")
                } else {
                    VStack(spacing: DS.Space.xxs) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, t in
                            FindingRow(index: i, highlight: (t.transactionSeconds ?? 0) > 3600 ? .warning : nil) { row(t) }
                        }
                    }
                    if items.contains(where: \.isIdleInTransaction) {
                        HStack(spacing: 8) {
                            Text("Tip: idle_in_transaction_session_timeout ends forgotten transactions automatically.")
                                .font(DS.Typo.caption).foregroundStyle(.secondary)
                            FixButton(title: "idle_in_transaction_session_timeout", label: "Set Timeout…",
                                      sql: InsightsFix.idleInTransactionTimeout(database: model.databaseName), open: model.openFix)
                        }
                    }
                }
            }
        }
    }

    func row(_ t: LongTransaction) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Tag("pid \(t.pid)", tone: .neutral)
                Text([t.user, t.application, t.clientAddress].compactMap { $0 }.joined(separator: " · ")).font(DS.Typo.callout)
                Tag(t.state ?? t.backendType ?? "?", tone: t.isIdleInTransaction ? .warning : .info)
                Text("transaction \(InsightsFormat.duration(t.transactionSeconds))")
                    .font(DS.Typo.callout.weight(.medium)).monospacedDigit()
                if t.isIdleInTransaction {
                    Text("idle for \(InsightsFormat.duration(t.stateSeconds))").font(DS.Typo.callout).foregroundStyle(.secondary)
                }
                Spacer()
                FixButton(title: "Terminate \(t.pid)", label: "Terminate…", sql: InsightsFix.terminateBackend(pid: t.pid), open: model.openFix)
            }
            if let q = t.query, !q.isEmpty {
                SQLSnippet(text: (t.isIdleInTransaction ? "last: " : "") + InsightsFormat.oneLine(q, limit: 400), lineLimit: 2)
            }
        }
    }
}

// MARK: Sequences

struct SequencesSection: View {
    @ObservedObject var model: InsightsDashboardModel

    var body: some View {
        let items = model.sequences.value ?? []
        InsightsCard(title: "Sequences", systemImage: "number",
                     subtitle: "Sequences that used more than \(Int(model.sequenceThreshold * 100))% of their range (capped by the owning column type).",
                     badge: model.sequences.value.map { "\($0.count)" },
                     badgeTone: items.isEmpty ? .neutral : .critical, isLoading: model.sequences.isLoading) {
            SectionBody(state: model.sequences, user: model.connectionUser, open: model.openFix) { items in
                if items.isEmpty {
                    EmptyFinding(text: "No sequence above \(Int(model.sequenceThreshold * 100))% of its maximum value.")
                } else {
                    VStack(spacing: DS.Space.xxs) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, s in
                            FindingRow(index: i, highlight: s.usedFraction > 0.9 ? .critical : .warning) { row(s) }
                        }
                    }
                }
            }
        }
    }

    func row(_ s: SequenceUsage) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("\(s.schema).\(s.name)").font(DS.Typo.callout.weight(.medium))
                    Tag(s.dataType, tone: .neutral)
                    if s.limitedByColumn { Tag("\(s.columnType ?? "") column", tone: .critical) }
                    if s.cycles { Tag("CYCLE", tone: .info) }
                }
                if let table = s.table, let column = s.column {
                    Text("owned by \(s.tableSchema ?? s.schema).\(table).\(column) (\(s.columnType ?? "?"))")
                        .font(DS.Typo.caption).foregroundStyle(.secondary)
                }
                Text("\(s.lastValue ?? "?") of \(s.effectiveMax ?? "?")").font(DS.Typo.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(InsightsFormat.percent(s.usedFraction)).font(DS.Typo.callout.weight(.semibold)).monospacedDigit()
                Meter(fraction: s.usedFraction, tone: s.usedFraction > 0.9 ? .critical : .warning).frame(width: 120, height: 4)
            }
            FixButton(title: "Widen \(s.name)", sql: InsightsFix.widenSequence(schema: s.schema, sequence: s.name, table: s.table,
                                                                                 tableSchema: s.tableSchema, column: s.column, columnType: s.columnType),
                      open: model.openFix)
        }
    }
}

// MARK: Vacuum

struct VacuumSection: View {
    @ObservedObject var model: InsightsDashboardModel

    var body: some View {
        let issues = model.vacuum.value?.issues ?? []
        InsightsCard(title: "Vacuum health", systemImage: "wind",
                     subtitle: "Tables whose dead tuples exceed the autovacuum threshold (or 20%), tables never analyzed, and transaction ID age.",
                     badge: model.vacuum.value.map { "\($0.issues.count)" },
                     badgeTone: issues.isEmpty ? .neutral : .warning, isLoading: model.vacuum.isLoading) {
            SectionBody(state: model.vacuum, user: model.connectionUser, open: model.openFix) { report in
                if !report.xidAges.isEmpty { xidView(report.xidAges) }
                if report.issues.isEmpty {
                    EmptyFinding(text: "Every table is below its autovacuum threshold and has been analyzed.")
                } else {
                    VStack(spacing: DS.Space.xxs) {
                        ForEach(Array(report.issues.enumerated()), id: \.element.id) { i, v in
                            FindingRow(index: i) { row(v) }
                        }
                    }
                }
                ForEach(report.errors, id: \.self) { SectionErrorView(message: $0) }
            }
        }
    }

    func xidView(_ ages: [XIDAge]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Transaction ID age (wraparound at 2.1 billion)").font(DS.Typo.caption).foregroundStyle(.secondary)
            ForEach(ages.prefix(4)) { a in
                HStack(spacing: 8) {
                    Text(a.database).font(DS.Typo.caption).frame(width: 120, alignment: .leading).lineLimit(1)
                    Meter(fraction: a.wraparoundFraction, tone: xidTone(a)).frame(height: 4)
                    Text("\(InsightsFormat.compact(a.age)) · \(InsightsFormat.percent(a.wraparoundFraction))")
                        .font(DS.Typo.caption).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 110, alignment: .trailing)
                }
            }
        }
        .padding(.bottom, 4)
    }

    func xidTone(_ a: XIDAge) -> Tone {
        a.wraparoundFraction > 0.5 ? .critical : a.age > a.freezeMaxAge ? .warning : .good
    }

    func row(_ v: VacuumIssue) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("\(v.schema).\(v.table)").font(DS.Typo.callout.weight(.medium))
                    if v.neverAnalyzed { Tag("never analyzed", tone: .warning) }
                    if v.aboveAutovacuumThreshold { Tag("above autovacuum threshold", tone: .warning) }
                }
                Text("\(InsightsFormat.count(v.deadTuples)) dead / \(InsightsFormat.count(v.liveTuples)) live (\(InsightsFormat.percent((v.deadPercent ?? 0) / 100))) · threshold \(InsightsFormat.count(v.autovacuumThreshold))")
                    .font(DS.Typo.caption).monospacedDigit().foregroundStyle(.secondary)
                Text("vacuumed \(InsightsFormat.ago(v.vacuumAgeSeconds)) · analyzed \(InsightsFormat.ago(v.analyzeAgeSeconds))")
                    .font(DS.Typo.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if v.needsVacuum || !v.neverAnalyzed {
                FixButton(title: "VACUUM \(v.table)", label: "VACUUM (ANALYZE)…",
                          sql: InsightsFix.vacuumAnalyze(schema: v.schema, table: v.table), open: model.openFix)
            } else {
                FixButton(title: "ANALYZE \(v.table)", label: "ANALYZE…",
                          sql: InsightsFix.analyze(schema: v.schema, table: v.table), open: model.openFix)
            }
        }
    }
}
