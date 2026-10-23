import Foundation
import MTPCore
import MTPUIKit
import SwiftUI

/// How an EXPLAIN statement is wrapped.
enum ExplainExecution: Equatable {
    /// Plain EXPLAIN: nothing is executed.
    case direct
    /// EXPLAIN ANALYZE of a read: BEGIN READ ONLY … ROLLBACK, so a "read" that writes fails instead.
    case readOnlyRollback
    /// EXPLAIN ANALYZE of a write: BEGIN … ROLLBACK.
    case rollback

    static func `for`(analyze: Bool, isWrite: Bool) -> ExplainExecution {
        guard analyze else { return .direct }
        return isWrite ? .rollback : .readOnlyRollback
    }

    func run(_ sql: String, on client: DBClient) async throws -> QueryResult {
        if self == .direct { return try await client.query(sql) }
        let begin = self == .readOnlyRollback ? "BEGIN TRANSACTION READ ONLY" : "BEGIN"
        return try await client.perform { d in
            guard !d.inTransaction else { throw DatabaseError("A transaction is already open on this connection") }
            _ = try d.execute(begin, params: [], maxRows: nil)
            defer { _ = try? d.execute("ROLLBACK", params: [], maxRows: nil) }
            return try d.execute(sql, params: [], maxRows: nil)
        }
    }
}

@MainActor
final class ExplainPlanModel: ObservableObject {
    let context: WorkspaceContext
    let originalSQL: String
    /// The statement without any EXPLAIN prefix.
    let statement: String
    let analysis: StatementAnalysis
    private var client: DBClient?
    private var runTask: Task<Void, Never>?

    @Published var analyze: Bool
    @Published var showText = false {
        didSet {
            if showText, textPlan == nil, plan != nil || sqlitePlan != nil { Task { await loadText() } }
        }
    }
    @Published private(set) var plan: ExplainPlan?
    @Published private(set) var json: String?
    @Published private(set) var textPlan: String?
    @Published private(set) var sqlitePlan: [SQLiteQueryPlanNode]?
    @Published private(set) var error: String?
    @Published private(set) var isRunning = false
    /// Options of the plan on screen (the toggle may have changed since).
    @Published private(set) var shownWithAnalyze = false
    @Published private(set) var shownRolledBack = false
    @Published private(set) var lastDuration: TimeInterval?
    @Published var expanded: Set<Int> = []
    @Published var collapsed: Set<Int> = []

    init(context: WorkspaceContext, sql: String) {
        self.context = context
        self.originalSQL = sql
        let inner = ExplainSQL.innerStatement(sql)
        self.statement = inner
        let a = QueryClassifier.analyze(inner, driver: context.connection.driver)
        self.analysis = a
        self.analyze = context.isPostgres && a.kind == .read
    }

    var isPostgres: Bool { context.isPostgres }
    /// Anything but a plain read is treated as a write for ANALYZE.
    var isWrite: Bool { analysis.kind != .read }
    var analyzeExecutesWrite: Bool { isPostgres && analyze && isWrite }

    func start() {
        if client == nil { client = context.makeClient(label: "explain") }
        if plan == nil && sqlitePlan == nil && error == nil && !isRunning { rerun() }
    }

    func stop() {
        runTask?.cancel()
        client?.cancel()
        client?.close()
        client = nil
    }

    func rerun() {
        runTask = Task { await run() }
    }

    func cancel() { client?.cancel() }

    func run() async {
        guard !statement.isEmpty else {
            error = "There is no statement to explain."
            return
        }
        if client == nil { client = context.makeClient(label: "explain") }
        guard let client else { return }
        let useAnalyze = isPostgres && analyze
        if useAnalyze && isWrite {
            let verb = analysis.verb.isEmpty ? "statement" : analysis.verb
            let summary = "EXPLAIN ANALYZE executes this \(verb) inside BEGIN … ROLLBACK on a separate connection. Triggers fire and sequences advance even though the changes are rolled back."
            guard await context.confirmWrite(sql: statement, summary: summary) else {
                error = "EXPLAIN ANALYZE was not confirmed. Turn ANALYZE off to see the estimated plan without executing the statement."
                return
            }
        }
        isRunning = true
        defer { isRunning = false }
        let started = Date()
        do {
            if isPostgres {
                let info = try await client.connect()
                let mode = ExplainExecution.for(analyze: useAnalyze, isWrite: isWrite)
                let sql = ExplainSQL.postgres(statement, format: .json, analyze: useAnalyze, serverVersion: info.numericVersion)
                let text = Self.joined(try await mode.run(sql, on: client))
                let parsed = try ExplainPlanParser.parse(json: text)
                var textOutput: String?
                if showText {
                    let textSQL = ExplainSQL.postgres(statement, format: .text, analyze: useAnalyze, serverVersion: info.numericVersion)
                    textOutput = Self.joined(try await mode.run(textSQL, on: client))
                }
                plan = parsed
                json = text
                textPlan = textOutput
                shownWithAnalyze = useAnalyze
                shownRolledBack = mode == .rollback
                expanded = []
                collapsed = []
            } else {
                let r = try await client.query(ExplainSQL.sqlite(statement))
                let nodes = SQLiteQueryPlan.build(from: r)
                sqlitePlan = nodes
                textPlan = Self.render(nodes)
            }
            error = nil
            lastDuration = Date().timeIntervalSince(started)
        } catch {
            self.error = Self.describe(error)
        }
    }

    private func loadText() async {
        guard isPostgres, let client else {
            if let sqlitePlan { textPlan = Self.render(sqlitePlan) }
            return
        }
        let useAnalyze = shownWithAnalyze
        if useAnalyze && isWrite {
            guard await context.confirmWrite(sql: statement, summary: "EXPLAIN ANALYZE (text) executes this statement again inside BEGIN … ROLLBACK.") else {
                showText = false
                return
            }
        }
        isRunning = true
        defer { isRunning = false }
        do {
            let info = try await client.connect()
            let sql = ExplainSQL.postgres(statement, format: .text, analyze: useAnalyze, serverVersion: info.numericVersion)
            textPlan = Self.joined(try await ExplainExecution.for(analyze: useAnalyze, isWrite: isWrite).run(sql, on: client))
        } catch {
            self.error = Self.describe(error)
        }
    }

    /// What "Copy plan" puts on the pasteboard.
    var copyText: String? {
        if showText, let textPlan { return textPlan }
        return json ?? textPlan
    }

    static func joined(_ r: QueryResult) -> String {
        r.rows.compactMap { $0.first ?? nil }.joined(separator: "\n")
    }

    static func render(_ nodes: [SQLiteQueryPlanNode]) -> String {
        nodes.flatMap(\.flattened).map { String(repeating: "   ", count: $0.depth) + "|--" + $0.detail }.joined(separator: "\n")
    }

    static func describe(_ error: Error) -> String {
        var m = error.insightsMessage
        if let db = error as? DatabaseError, db.sqlState == "25006" {
            m += "\nEXPLAIN ANALYZE of a read runs in a read-only transaction; this statement tried to write or lock rows."
        }
        return m
    }

    /// Nodes on screen, honouring collapsed subtrees.
    func visibleNodes(_ plan: ExplainPlan) -> [PlanNode] {
        var out: [PlanNode] = []
        func walk(_ n: PlanNode) {
            out.append(n)
            guard !collapsed.contains(n.id) else { return }
            n.children.forEach(walk)
        }
        walk(plan.root)
        return out
    }

    func toggleDetails(_ id: Int) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    func toggleCollapsed(_ id: Int) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
    }
}
