import MTPCore
import MTPUIKit
import SwiftUI

// Public entry points used by the app. Keep these signatures stable.

/// PostgreSQL health dashboard: sizes, cache hit, bloat, unused indexes, slow queries, locks, long transactions.
/// SQLite connections get a smaller file-level view.
public struct InsightsDashboardView: View {
    let context: WorkspaceContext
    public init(context: WorkspaceContext) { self.context = context }

    public var body: some View {
        if context.isPostgres {
            PostgresDashboardHost(context: context)
        } else {
            SQLiteDashboardHost(context: context)
        }
    }
}

/// Live pg_stat_activity with cancel / terminate (TablePlus "Process List", ⌘.).
public struct ProcessListView: View {
    let context: WorkspaceContext
    public init(context: WorkspaceContext) { self.context = context }

    public var body: some View {
        if context.isPostgres {
            ProcessListHost(context: context)
        } else {
            NotSupportedView(title: "Process list is not supported",
                             message: "SQLite is an embedded database: there are no server processes to list. The process list is available for PostgreSQL connections.")
        }
    }
}

/// Visual EXPLAIN (ANALYZE) for one statement.
public struct ExplainPlanView: View {
    let context: WorkspaceContext
    let sql: String
    public init(context: WorkspaceContext, sql: String) {
        self.context = context
        self.sql = sql
    }

    public var body: some View {
        ExplainPlanHost(context: context, sql: sql)
            // A new statement gets a fresh model.
            .id(sql)
    }
}

// MARK: - Hosts owning the models (StateObject keeps them across view updates)

struct PostgresDashboardHost: View {
    @StateObject private var model: InsightsDashboardModel

    init(context: WorkspaceContext) {
        _model = StateObject(wrappedValue: InsightsDashboardModel(context: context))
    }

    var body: some View {
        InsightsDashboardContent(model: model)
            .onAppear { model.start() }
            .onDisappear { model.stop() }
    }
}

struct SQLiteDashboardHost: View {
    @StateObject private var model: SQLiteInsightsModel

    init(context: WorkspaceContext) {
        _model = StateObject(wrappedValue: SQLiteInsightsModel(context: context))
    }

    var body: some View {
        SQLiteInsightsContent(model: model)
            .onAppear { model.start() }
            .onDisappear { model.stop() }
    }
}

struct ProcessListHost: View {
    @StateObject private var model: ProcessListModel

    init(context: WorkspaceContext) {
        _model = StateObject(wrappedValue: ProcessListModel(context: context))
    }

    var body: some View {
        ProcessListContent(model: model)
            .onAppear { model.start() }
            .onDisappear { model.stop() }
    }
}

struct ExplainPlanHost: View {
    @StateObject private var model: ExplainPlanModel

    init(context: WorkspaceContext, sql: String) {
        _model = StateObject(wrappedValue: ExplainPlanModel(context: context, sql: sql))
    }

    var body: some View {
        ExplainPlanContent(model: model)
            .onAppear { model.start() }
            .onDisappear { model.stop() }
    }
}
