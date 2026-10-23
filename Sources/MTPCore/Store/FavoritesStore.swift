import Foundation

public extension Notification.Name {
    static let mtpFavoritesDidChange = Notification.Name("MTPFavoritesDidChange")
}

/// A saved query (TablePlus "Favorites"). `keyword` expands in the editor like a snippet.
public struct SavedQuery: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var sql: String
    public var keyword: String
    public var folder: String
    /// nil = available on every connection.
    public var connectionID: UUID?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, sql: String, keyword: String = "", folder: String = "", connectionID: UUID? = nil) {
        self.id = id
        self.name = name
        self.sql = sql
        self.keyword = keyword
        self.folder = folder
        self.connectionID = connectionID
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

public final class FavoritesStore: @unchecked Sendable {
    public static let shared = FavoritesStore()

    private let lock = NSLock()
    private let url: URL
    private var items: [SavedQuery] = []

    public init(url: URL = AppPaths.favoritesFile) {
        self.url = url
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url), let decoded = try? decoder.decode([SavedQuery].self, from: data) {
            items = decoded
        }
    }

    public func all(for connectionID: UUID? = nil) -> [SavedQuery] {
        lock.lock(); defer { lock.unlock() }
        guard let connectionID else { return items }
        return items.filter { $0.connectionID == nil || $0.connectionID == connectionID }
    }

    public func upsert(_ q: SavedQuery) {
        lock.lock()
        var q = q
        q.updatedAt = Date()
        if let i = items.firstIndex(where: { $0.id == q.id }) { items[i] = q } else { items.append(q) }
        lock.unlock()
        save()
    }

    public func delete(_ id: UUID) {
        lock.lock()
        items.removeAll { $0.id == id }
        lock.unlock()
        save()
    }

    private func save() {
        lock.lock()
        let snapshot = items
        lock.unlock()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(snapshot) { try? data.write(to: url, options: .atomic) }
        NotificationCenter.default.post(name: .mtpFavoritesDidChange, object: self)
    }
}
