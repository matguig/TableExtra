import Foundation
import MTPCore

public struct TablePlusImportSummary: Sendable, Equatable {
    public var connections = 0
    public var groups = 0
    public var passwords = 0
    public var historyEntries = 0
}

/// Commits part of a `TablePlusImporter.Preview`: only the selected connections, their groups,
/// and optionally their Keychain passwords and query history.
public enum TablePlusMigration {
    public static func run(importer: TablePlusImporter, preview: TablePlusImporter.Preview, selected: Set<UUID>,
                           importPasswords: Bool, importHistory: Bool,
                           store: ConnectionStore = .shared, history: HistoryStore = .shared) -> TablePlusImportSummary {
        var summary = TablePlusImportSummary()
        let chosen = preview.connections.filter { selected.contains($0.id) }

        // Reuse groups imported earlier (same TablePlus ID) instead of creating duplicates.
        var groupIDs: [UUID: UUID] = [:]
        for g in preview.groups where chosen.contains(where: { $0.groupID == g.id }) {
            if let existing = store.groups.first(where: { $0.tablePlusID != nil && $0.tablePlusID == g.tablePlusID }) {
                groupIDs[g.id] = existing.id
            } else {
                store.upsertGroup(g)
                groupIDs[g.id] = g.id
                summary.groups += 1
            }
        }

        var imported: [String: ConnectionConfig] = [:]
        for var c in chosen {
            if let gid = c.groupID { c.groupID = groupIDs[gid] }
            var secrets: ConnectionSecrets?
            if importPasswords {
                let s = importer.password(for: c)
                if s.password?.isEmpty == false { summary.passwords += 1 }
                secrets = s
            }
            store.upsert(c, secrets: secrets)
            summary.connections += 1
            if let tp = c.tablePlusID { imported[tp] = c }
        }

        if importHistory {
            for (tpID, url) in historyFiles(in: importer.dataDirectory) {
                guard let c = imported[tpID], let sql = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let stamp = Double(url.deletingPathExtension().lastPathComponent) ?? 0
                history.add(connectionID: c.id, database: c.database, sql: sql, duration: 0, rowCount: nil, error: nil,
                            source: "tableplus", at: Date(timeIntervalSinceReferenceDate: stamp))
                summary.historyEntries += 1
            }
            history.flush()
        }
        return summary
    }

    /// Data/History/<ConnectionID>/<day>/<seconds since 2001>.sql
    public static func historyFiles(in dataDirectory: URL) -> [(String, URL)] {
        let root = dataDirectory.appendingPathComponent("History")
        let fm = FileManager.default
        guard let conns = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        var out: [(String, URL)] = []
        for conn in conns.sorted() {
            let connDir = root.appendingPathComponent(conn)
            guard let days = try? fm.contentsOfDirectory(atPath: connDir.path) else { continue }
            for day in days {
                let dayDir = connDir.appendingPathComponent(day)
                guard let files = try? fm.contentsOfDirectory(atPath: dayDir.path) else { continue }
                for f in files.sorted() where f.hasSuffix(".sql") { out.append((conn, dayDir.appendingPathComponent(f))) }
            }
        }
        return out
    }

    /// History files per TablePlus connection ID.
    public static func historyCounts(in dataDirectory: URL) -> [String: Int] {
        var counts: [String: Int] = [:]
        for (id, _) in historyFiles(in: dataDirectory) { counts[id, default: 0] += 1 }
        return counts
    }
}
