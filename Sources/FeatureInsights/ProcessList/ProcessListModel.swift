import Foundation
import MTPCore
import MTPUIKit
import SwiftUI

/// One row of pg_stat_activity.
public struct PGProcess: Identifiable, Sendable, Hashable {
    public var pid: Int
    public var database: String
    public var user: String
    public var application: String
    public var clientAddress: String
    public var clientHostname: String?
    public var clientPort: Int?
    public var backendType: String
    public var state: String
    public var waitEventType: String?
    public var waitEvent: String?
    public var backendSeconds: Double?
    public var transactionSeconds: Double?
    public var querySeconds: Double?
    public var stateSeconds: Double?
    public var isSelf: Bool
    public var blockedBy: [Int]
    public var backendXID: String?
    public var backendXmin: String?
    public var query: String

    public var id: Int { pid }

    public var isIdle: Bool { state == "idle" }
    public var isActive: Bool { state == "active" }
    public var isIdleInTransaction: Bool { state.hasPrefix("idle in transaction") }
    /// Background processes (checkpointer, walwriter…); autovacuum and parallel workers count as user work.
    public var isSystem: Bool {
        !["client backend", "autovacuum worker", "parallel worker", ""].contains(backendType)
    }

    /// Active: time in the current query. Otherwise: time in the current state.
    public var duration: Double {
        let d = isActive ? (querySeconds ?? stateSeconds) : (stateSeconds ?? querySeconds)
        return max(0, d ?? backendSeconds ?? 0)
    }

    public var waitDescription: String {
        switch (waitEventType, waitEvent) {
        case let (t?, e?): return "\(t): \(e)"
        case let (t?, nil): return t
        case let (nil, e?): return e
        default: return ""
        }
    }

    /// Single-line query for the grid.
    public var queryPreview: String {
        let collapsed = query.split(whereSeparator: { $0.isNewline || $0 == "\t" }).joined(separator: " ")
        let squeezed = collapsed.replacingOccurrences(of: " +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return squeezed.count > 300 ? String(squeezed.prefix(300)) + "…" : squeezed
    }

    func matches(_ filter: String) -> Bool {
        let f = filter.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty else { return true }
        if String(pid) == f { return true }
        return [database, user, application, clientAddress, state, backendType, waitDescription, query]
            .contains { $0.localizedCaseInsensitiveContains(f) }
    }

    init(row r: ResultRow) {
        pid = Int(r.int("pid") ?? 0)
        database = r.text("datname")
        user = r.text("usename")
        application = r.text("application_name")
        clientAddress = r.text("client_addr")
        clientHostname = r.string("client_hostname")
        clientPort = r.int("client_port").map { Int($0) }
        backendType = r.text("backend_type")
        state = r.text("state")
        waitEventType = r.string("wait_event_type")
        waitEvent = r.string("wait_event")
        backendSeconds = r.double("backend_seconds")
        transactionSeconds = r.double("xact_seconds").map { max(0, $0) }
        querySeconds = r.double("query_seconds").map { max(0, $0) }
        stateSeconds = r.double("state_seconds").map { max(0, $0) }
        isSelf = r.flag("is_self")
        blockedBy = (r.string("blocked_by") ?? "").split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        backendXID = r.string("backend_xid")
        backendXmin = r.string("backend_xmin")
        query = r.text("query")
    }
}

public enum ProcessSignal: Sendable {
    case cancel, terminate

    var function: String { self == .cancel ? "pg_cancel_backend" : "pg_terminate_backend" }
    var verb: String { self == .cancel ? "Cancel" : "Terminate" }
}

@MainActor
final class ProcessListModel: ObservableObject {
    let context: WorkspaceContext
    private var client: DBClient?
    private var autoTask: Task<Void, Never>?
    private var loading = false

    @Published private(set) var processes: [PGProcess] = []
    @Published private(set) var error: String?
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var isLoading = false
    @Published var showIdle = false
    @Published var showOwn = false
    @Published var showSystem = false
    @Published var filter = ""
    @Published var selection: Int?
    @Published var sortOrder: [KeyPathComparator<PGProcess>] = [KeyPathComparator(\PGProcess.duration, order: .reverse)]
    @Published var autoRefresh = true {
        didSet { autoRefresh ? startTimer() : stopTimer() }
    }

    static let interval: UInt64 = 2_000_000_000

    init(context: WorkspaceContext) {
        self.context = context
    }

    var isSupported: Bool { context.isPostgres }

    var visible: [PGProcess] {
        processes
            .filter { (showIdle || !$0.isIdle) && (showOwn || !$0.isSelf) && (showSystem || !$0.isSystem) && $0.matches(filter) }
            .sorted(using: sortOrder)
    }

    var selected: PGProcess? { selection.flatMap { pid in processes.first { $0.pid == pid } } }

    func start() {
        guard isSupported else { return }
        if client == nil {
            let c = context.makeClient(label: "process-list")
            client = c
            Task { _ = try? await c.query(InsightsSQL.processListSession) }
        }
        Task { await refresh() }
        if autoRefresh { startTimer() }
    }

    func stop() {
        stopTimer()
        client?.close()
        client = nil
    }

    private func startTimer() {
        guard autoTask == nil, client != nil else { return }
        autoTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.interval)
                guard !Task.isCancelled, let self else { return }
                await self.refresh()
            }
        }
    }

    private func stopTimer() {
        autoTask?.cancel()
        autoTask = nil
    }

    func refresh() async {
        guard let client, !loading else { return }
        loading = true
        isLoading = true
        defer {
            loading = false
            isLoading = false
        }
        do {
            let rows = try await client.query(InsightsSQL.activity).typedRows
            processes = rows.map(PGProcess.init(row:))
            error = nil
            lastRefresh = Date()
        } catch {
            self.error = error.insightsMessage
        }
    }

    /// Sends the signal after `confirmWrite`; returns true when PostgreSQL accepted it.
    @discardableResult
    func send(_ signal: ProcessSignal, to process: PGProcess) async -> Bool {
        guard let client else { return false }
        let sql = "SELECT \(signal.function)(\(process.pid))"
        let who = [process.user, process.application].filter { !$0.isEmpty }.joined(separator: " · ")
        let summary = signal == .cancel
            ? "Cancel the running query of process \(process.pid)\(who.isEmpty ? "" : " (\(who))")."
            : "Terminate process \(process.pid)\(who.isEmpty ? "" : " (\(who))"). Its open transaction is rolled back."
        guard await context.confirmWrite(sql: sql, summary: summary) else { return false }
        do {
            let r = try await client.query(sql)
            let ok = r.typedRows.first.flatMap { $0.bool(r.columns.first?.name ?? "") } ?? false
            if ok {
                context.showToast("\(signal.verb) signal sent to process \(process.pid)")
            } else {
                context.showError(DatabaseError("Process \(process.pid) was not signalled",
                                                detail: "It may have finished already, or it is not a PostgreSQL backend."))
            }
            await refresh()
            return ok
        } catch {
            context.showError(error)
            return false
        }
    }
}

extension ProcessListModel {
    /// Sessions as text for Claude (queries truncated).
    func sessionsForClaude() -> AIAttachment {
        var text = ""
        for p in processes.prefix(80) {
            var line = ""
            dump(p, to: &line, maxDepth: 2)
            text += line.count > 1_500 ? String(line.prefix(1_500)) + "…\n" : line
        }
        return AIAttachments.text(text.isEmpty ? "No session" : text, title: "\(processes.count) sessions", systemImage: "list.bullet.rectangle",
                                  containsRowData: true)
    }
}

