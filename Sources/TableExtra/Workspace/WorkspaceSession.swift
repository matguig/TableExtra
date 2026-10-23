import Foundation
import MTPCore

/// Reopens workspaces and their tabs at launch (TablePlus Settings.json "closedWorkspaces").
@MainActor
enum WorkspaceSession {
    struct Tab: Codable {
        var kind: String
        var schema: String?
        var name: String?
        var mode: String?
        var title: String?
        var sql: String?
        var file: String?
    }

    struct State: Codable {
        var connectionID: UUID
        var database: String?
        var schema: String?
        var tabs: [Tab]
        var selectedIndex: Int?
    }

    static func state(of m: WorkspaceModel) -> State {
        let tabs: [Tab] = m.tabs.compactMap { t in
            if let t = t as? TableTabModel {
                return Tab(kind: "table", schema: t.object.schema, name: t.object.name, mode: t.mode.rawValue)
            }
            if let q = t as? QueryTabModel {
                return Tab(kind: "query", title: q.title, sql: q.sql, file: q.fileURL?.path)
            }
            return nil
        }
        return State(connectionID: m.connection.id, database: m.currentDatabase, schema: m.currentSchema,
                     tabs: tabs, selectedIndex: m.tabs.firstIndex { $0.id == m.selectedTabID })
    }

    /// Saves open workspaces. When a window closes on its own, its state is kept so it can be reopened later.
    static func save(_ models: [WorkspaceModel], closing: WorkspaceModel? = nil) {
        var states = models.filter { ConnectionStore.shared.connection($0.connection.id) != nil }.map(state(of:))
        if let closing {
            // Closing the last window: remember it; closing one of several: forget it.
            if models.count > 1 { states.removeAll { $0.connectionID == closing.connection.id } }
        }
        if let data = try? JSONEncoder().encode(states) {
            try? data.write(to: AppPaths.workspaceStateFile, options: .atomic)
        }
    }

    static func load() -> [State] {
        guard let data = try? Data(contentsOf: AppPaths.workspaceStateFile) else { return [] }
        return (try? JSONDecoder().decode([State].self, from: data)) ?? []
    }

    /// Last state saved for one connection (used when reopening it from the welcome window).
    static func lastState(for id: UUID) -> State? { load().first { $0.connectionID == id } }
}
