import Foundation

/// One-click migration from TablePlus: connections, groups, Keychain passwords and query history.
///
/// Observed TablePlus 27 layout (reverse-engineered from the installed app):
///  - Data/Connections.plist: array of dictionaries (Driver, ConnectionName, DatabaseHost, DatabasePort as String,
///    DatabaseUser, DatabaseName, DatabasePath, Enviroment [sic], statusColor, GroupID, tLSMode, isOverSSH,
///    ServerAddress, ServerPort, ServerUser, StartupCommands, ...)
///  - Data/ConnectionGroups.plist: array of {ID, Name}
///  - Keychain: service "com.tableplus.TablePlus", account "<ID>_database" (and "<ID>_server" for SSH)
///  - Data/History/<ConnectionID>/<d MMMM yyyy>/<seconds since 2001>.sql, one statement per file
public struct TablePlusImporter {
    public struct Preview: Sendable {
        public var connections: [ConnectionConfig]
        public var groups: [ConnectionGroup]
        /// TablePlus drivers TableExtra does not support yet.
        public var skipped: [(name: String, driver: String)]
        public var historyFileCount: Int
    }

    public let dataDirectory: URL

    public init(dataDirectory: URL = AppPaths.tablePlusData) {
        self.dataDirectory = dataDirectory
    }

    public var isAvailable: Bool {
        FileManager.default.fileExists(atPath: dataDirectory.appendingPathComponent("Connections.plist").path)
    }

    public func preview(existing: [ConnectionConfig] = []) throws -> Preview {
        let groupsRaw = (try? plist(at: "ConnectionGroups.plist") as? [[String: Any]]) ?? []
        var groups: [ConnectionGroup] = []
        var groupMap: [String: UUID] = [:]
        for g in groupsRaw {
            guard let tpID = g["ID"] as? String else { continue }
            let group = ConnectionGroup(name: g["Name"] as? String ?? "Group", tablePlusID: tpID)
            groupMap[tpID] = group.id
            groups.append(group)
        }

        guard let raw = try plist(at: "Connections.plist") as? [[String: Any]] else {
            throw DatabaseError("Connections.plist has an unexpected format")
        }
        let alreadyImported = Set(existing.compactMap(\.tablePlusID))
        var connections: [ConnectionConfig] = []
        var skipped: [(String, String)] = []
        for d in raw {
            let name = d["ConnectionName"] as? String ?? "Connection"
            let driverName = d["Driver"] as? String ?? ""
            let driver: DriverKind
            switch driverName.lowercased() {
            case "postgresql", "postgres", "redshift", "cockroach", "greenplum": driver = .postgres
            case "sqlite": driver = .sqlite
            default:
                skipped.append((name, driverName))
                continue
            }
            guard let tpID = d["ID"] as? String, !alreadyImported.contains(tpID) else { continue }
            let envRaw = (d["Enviroment"] as? String ?? d["Environment"] as? String ?? "").lowercased()
            let env: ConnectionEnvironment
            switch envRaw {
            case "production", "prod": env = .production
            case "staging": env = .staging
            case "testing", "test": env = .testing
            case "development", "dev": env = .development
            default: env = .local
            }
            var c = ConnectionConfig(name: name, driver: driver, environment: env, tablePlusID: tpID)
            c.host = d["DatabaseHost"] as? String ?? ""
            c.port = Int(d["DatabasePort"] as? String ?? "") ?? (d["DatabasePort"] as? Int)
            c.user = d["DatabaseUser"] as? String ?? ""
            c.database = d["DatabaseName"] as? String ?? ""
            c.filePath = d["DatabasePath"] as? String ?? ""
            c.colorHex = d["statusColor"] as? String
            if let gid = d["GroupID"] as? String { c.groupID = groupMap[gid] }
            // Only mode 0 (TablePlus default, "prefer") has been observed; others are best-effort.
            switch d["tLSMode"] as? Int ?? 0 {
            case 1: c.sslMode = .require
            case 2: c.sslMode = .verifyCA
            case 3: c.sslMode = .verifyFull
            case 4: c.sslMode = .disable
            default: c.sslMode = .prefer
            }
            if (d["isOverSSH"] as? Bool) == true {
                var ssh = SSHConfig()
                ssh.enabled = true
                ssh.host = d["ServerAddress"] as? String ?? ""
                ssh.port = Int(d["ServerPort"] as? String ?? "") ?? 22
                ssh.user = d["ServerUser"] as? String ?? ""
                c.ssh = ssh
            }
            if let startup = d["StartupCommands"] as? String { c.startupSQL = startup }
            else if let startup = d["StartupCommands"] as? [String] { c.startupSQL = startup.joined(separator: ";\n") }
            if c.host.isEmpty, driver == .postgres { c.host = "127.0.0.1" }
            connections.append(c)
        }
        return Preview(connections: connections, groups: groups.filter { g in connections.contains { $0.groupID == g.id } },
                       skipped: skipped, historyFileCount: historyFiles().count)
    }

    /// Reads the TablePlus Keychain item; macOS asks the user to allow access once per item.
    public func password(for config: ConnectionConfig) -> ConnectionSecrets {
        guard let id = config.tablePlusID else { return ConnectionSecrets() }
        return ConnectionSecrets(password: Keychain.get(account: "\(id)_database", service: Keychain.tablePlusService),
                                 sshPassword: Keychain.get(account: "\(id)_server", service: Keychain.tablePlusService))
    }

    /// Saves connections and passwords, then imports query history. Returns the number of history entries.
    @discardableResult
    public func commit(_ preview: Preview, into store: ConnectionStore = .shared, history: HistoryStore = .shared, importPasswords: Bool = true) -> Int {
        for g in preview.groups where !store.groups.contains(where: { $0.tablePlusID == g.tablePlusID }) {
            store.upsertGroup(g)
        }
        for c in preview.connections {
            store.upsert(c, secrets: importPasswords ? password(for: c) : nil)
        }
        var idMap: [String: UUID] = [:]
        for c in store.connections { if let tp = c.tablePlusID { idMap[tp] = c.id } }
        var count = 0
        for (tpID, url) in historyFiles() {
            guard let id = idMap[tpID], let sql = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let stamp = Double(url.deletingPathExtension().lastPathComponent) ?? 0
            let date = Date(timeIntervalSinceReferenceDate: stamp)
            history.add(connectionID: id, database: "", sql: sql, duration: 0, rowCount: nil, error: nil, source: "tableplus", at: date)
            count += 1
        }
        history.flush()
        return count
    }

    func historyFiles() -> [(String, URL)] {
        let root = dataDirectory.appendingPathComponent("History")
        let fm = FileManager.default
        guard let conns = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        var out: [(String, URL)] = []
        for conn in conns {
            let connDir = root.appendingPathComponent(conn)
            guard let days = try? fm.contentsOfDirectory(atPath: connDir.path) else { continue }
            for day in days {
                let dayDir = connDir.appendingPathComponent(day)
                guard let files = try? fm.contentsOfDirectory(atPath: dayDir.path) else { continue }
                for f in files where f.hasSuffix(".sql") { out.append((conn, dayDir.appendingPathComponent(f))) }
            }
        }
        return out
    }

    private func plist(at name: String) throws -> Any {
        let url = dataDirectory.appendingPathComponent(name)
        let data = try Data(contentsOf: url)
        return try PropertyListSerialization.propertyList(from: data, format: nil)
    }
}
