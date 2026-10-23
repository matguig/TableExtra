import Foundation
import MTPCore
import MTPUIKit
import SwiftUI

/// Result of one dashboard section; sections load and fail independently.
struct SectionState<Value> {
    var value: Value?
    var error: String?
    var isPermissionError = false
    var isLoading = false
    var updatedAt: Date?

    var isEmptyLoading: Bool { isLoading && value == nil && error == nil }
}

enum RefreshScope {
    /// Every section.
    case all
    /// Sections that change from second to second (auto-refresh).
    case live
}

@MainActor
final class InsightsDashboardModel: ObservableObject {
    let context: WorkspaceContext
    private(set) var client: DBClient?
    private var insights: PostgresInsights?
    private var autoTask: Task<Void, Never>?
    private var inFlight = 0

    @Published var overview = SectionState<OverviewStats>()
    @Published var tables = SectionState<[TableStat]>()
    @Published var indexes = SectionState<IndexReport>()
    @Published var statements = SectionState<StatementsReport>()
    @Published var blocking = SectionState<[BlockingPair]>()
    @Published var longTransactions = SectionState<[LongTransaction]>()
    @Published var sequences = SectionState<[SequenceUsage]>()
    @Published var vacuum = SectionState<VacuumReport>()
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var isRefreshing = false
    @Published var autoRefresh = false {
        didSet { autoRefresh ? startTimer() : stopTimer() }
    }

    static let autoRefreshInterval: UInt64 = 5_000_000_000
    /// Sequences above this share of their range are reported.
    var sequenceThreshold = 0.75
    var longTransactionSeconds = 60

    init(context: WorkspaceContext) {
        self.context = context
    }

    func start() {
        guard context.isPostgres else { return }
        if client == nil {
            let c = context.makeClient(label: "insights")
            client = c
            insights = PostgresInsights(client: c)
        }
        if lastRefresh == nil { Task { await refresh(.all) } }
        if autoRefresh { startTimer() }
    }

    func stop() {
        stopTimer()
        client?.close()
        client = nil
        insights = nil
    }

    private func startTimer() {
        guard autoTask == nil, client != nil else { return }
        autoTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.autoRefreshInterval)
                guard !Task.isCancelled, let self else { return }
                if !self.isRefreshing { await self.refresh(.live) }
            }
        }
    }

    private func stopTimer() {
        autoTask?.cancel()
        autoTask = nil
    }

    /// Loads sections concurrently (they queue on the dedicated connection) and returns when all finished.
    func refresh(_ scope: RefreshScope = .all) async {
        guard let insights else { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            lastRefresh = Date()
        }
        // Re-applied each time: the driver silently reconnects after a dropped connection.
        _ = try? await insights.prepareSession()
        let seqThreshold = sequenceThreshold
        let longSeconds = longTransactionSeconds
        // Sections run concurrently as child tasks; each writes back to its own state on the main actor.
        async let o: Void = load({ $0.overview = $1 }, { $0.overview }) { try await insights.overview() }
        async let b: Void = load({ $0.blocking = $1 }, { $0.blocking }) { try await insights.blocking() }
        async let l: Void = load({ $0.longTransactions = $1 }, { $0.longTransactions }) {
            try await insights.longTransactions(minSeconds: longSeconds)
        }
        async let s: Void = load({ $0.statements = $1 }, { $0.statements }) { try await insights.statements() }
        if scope == .all {
            async let t: Void = load({ $0.tables = $1 }, { $0.tables }) { try await insights.tables() }
            async let i: Void = load({ $0.indexes = $1 }, { $0.indexes }) { try await insights.indexReport() }
            async let v: Void = load({ $0.vacuum = $1 }, { $0.vacuum }) { try await insights.vacuumReport() }
            async let q: Void = load({ $0.sequences = $1 }, { $0.sequences }) {
                try await insights.sequences(threshold: seqThreshold)
            }
            _ = await (t, i, v, q)
        }
        _ = await (o, b, l, s)
    }

    private func load<T>(_ set: @MainActor (InsightsDashboardModel, SectionState<T>) -> Void,
                         _ get: @MainActor (InsightsDashboardModel) -> SectionState<T>,
                         _ work: @escaping @Sendable () async throws -> T) async {
        var state = get(self)
        state.isLoading = true
        set(self, state)
        do {
            let value = try await work()
            state = get(self)
            state.value = value
            state.error = nil
            state.isPermissionError = false
        } catch {
            state = get(self)
            state.error = error.insightsMessage
            state.isPermissionError = error.isPermissionDenied
        }
        state.isLoading = false
        state.updatedAt = Date()
        set(self, state)
    }

    func openFix(title: String, sql: String) {
        context.openQueryTab(title: title, sql: sql, run: false)
    }

    var connectionUser: String { context.serverInfo?.currentUser ?? context.connection.user }
    var databaseName: String { context.serverInfo?.currentDatabase ?? context.currentDatabase }
}

// MARK: - Claude

extension InsightsDashboardModel {
    /// Everything the dashboard loaded, as plain text for Claude (sections that failed say why).
    func reportForClaude() -> String {
        var out = "PostgreSQL health report for database \(context.currentDatabase)\n"
        func section<T>(_ title: String, _ state: SectionState<T>) {
            out += "\n## \(title)\n"
            if let error = state.error { out += "Not available: \(error)\n"; return }
            guard let value = state.value else { out += "Not loaded\n"; return }
            var text = ""
            dump(value, to: &text, maxDepth: 4, maxItems: 400)
            out += text.count > 8_000 ? String(text.prefix(8_000)) + "\n… (truncated)\n" : text
        }
        section("Overview", overview)
        section("Locks and blocking", blocking)
        section("Long-running transactions", longTransactions)
        section("Slow queries (pg_stat_statements)", statements)
        section("Tables", tables)
        section("Indexes", indexes)
        section("Sequences close to their limit", sequences)
        section("Vacuum", vacuum)
        return out
    }

    var claudeItems: [AskClaudeItem] {
        let report = { AIAttachments.text(self.reportForClaude(), title: "Health report", systemImage: "stethoscope") }
        return [
            AskClaudeItem("What Should I Fix First?", systemImage: "list.number") {
                AIRequest(title: "Prioritize findings", prompt: """
                    From this health report, list what deserves attention, most urgent first, with the reason and the exact SQL to investigate \
                    or fix each item (in one ```sql block). Say clearly when everything looks healthy.
                    """, attachments: [report()])
            },
            AskClaudeItem("Explain This Dashboard", systemImage: "text.book.closed") {
                AIRequest(title: "Explain health report", prompt: "Explain what these numbers say about this database's health, in plain language, briefly.",
                          attachments: [report()])
            },
            AskClaudeItem("Review Indexes", systemImage: "bolt.horizontal") {
                AIRequest(title: "Review indexes", prompt: """
                    Using the index section (unused, duplicate, largest) and table scans, say which indexes to drop or add. \
                    Mention risks (unique/PK constraints, replicas that may use them). DROP/CREATE INDEX CONCURRENTLY in one ```sql block.
                    """, attachments: [report()])
            },
            AskClaudeItem("Explain the Slowest Queries", systemImage: "tortoise") {
                AIRequest(title: "Slow queries", prompt: "Explain why the top slow queries are slow and how to speed them up (indexes, rewrites).",
                          attachments: [report()])
            },
        ]
    }
}

