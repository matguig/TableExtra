import Foundation

public extension Notification.Name {
    static let mtpConnectionsDidChange = Notification.Name("MTPConnectionsDidChange")
}

/// connections.json: connections and groups, never secrets.
public final class ConnectionStore: @unchecked Sendable {
    public static let shared = ConnectionStore()

    struct FileFormat: Codable {
        var version = 1
        var connections: [ConnectionConfig]
        var groups: [ConnectionGroup]
    }

    private let lock = NSLock()
    private let url: URL
    private var _connections: [ConnectionConfig] = []
    private var _groups: [ConnectionGroup] = []

    public init(url: URL = AppPaths.connectionsFile) {
        self.url = url
        reload()
    }

    public func reload() {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let file = try? decoder.decode(FileFormat.self, from: data) {
            _connections = file.connections
            _groups = file.groups
        }
    }

    public var connections: [ConnectionConfig] {
        lock.lock(); defer { lock.unlock() }
        return _connections
    }

    public var groups: [ConnectionGroup] {
        lock.lock(); defer { lock.unlock() }
        return _groups
    }

    public func connection(_ id: UUID) -> ConnectionConfig? { connections.first { $0.id == id } }

    /// Lookup by id, exact name, or case-insensitive name (used by the MCP server).
    public func find(_ key: String) -> ConnectionConfig? {
        let all = connections
        if let id = UUID(uuidString: key), let c = all.first(where: { $0.id == id }) { return c }
        return all.first { $0.name == key } ?? all.first { $0.name.caseInsensitiveCompare(key) == .orderedSame }
    }

    public func upsert(_ config: ConnectionConfig, secrets: ConnectionSecrets? = nil) {
        lock.lock()
        if let i = _connections.firstIndex(where: { $0.id == config.id }) {
            _connections[i] = config
        } else {
            _connections.append(config)
        }
        lock.unlock()
        if let secrets { Keychain.store(secrets, for: config.id) }
        save()
    }

    public func delete(_ id: UUID) {
        lock.lock()
        _connections.removeAll { $0.id == id }
        lock.unlock()
        Keychain.removeSecrets(for: id)
        save()
    }

    public func markConnected(_ id: UUID) {
        lock.lock()
        if let i = _connections.firstIndex(where: { $0.id == id }) { _connections[i].lastConnectedAt = Date() }
        lock.unlock()
        save()
    }

    public func upsertGroup(_ group: ConnectionGroup) {
        lock.lock()
        if let i = _groups.firstIndex(where: { $0.id == group.id }) { _groups[i] = group } else { _groups.append(group) }
        lock.unlock()
        save()
    }

    public func deleteGroup(_ id: UUID) {
        lock.lock()
        _groups.removeAll { $0.id == id }
        for i in _connections.indices where _connections[i].groupID == id { _connections[i].groupID = nil }
        lock.unlock()
        save()
    }

    public func replaceAll(connections: [ConnectionConfig], groups: [ConnectionGroup]) {
        lock.lock()
        _connections = connections
        _groups = groups
        lock.unlock()
        save()
    }

    public func secrets(for id: UUID) -> ConnectionSecrets { Keychain.secrets(for: id) }

    public func save() {
        lock.lock()
        let file = FileFormat(connections: _connections, groups: _groups)
        lock.unlock()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(file) {
            try? data.write(to: url, options: .atomic)
        }
        NotificationCenter.default.post(name: .mtpConnectionsDidChange, object: self)
    }
}
