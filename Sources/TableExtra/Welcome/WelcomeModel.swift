import AppKit
import MTPCore
import Observation

/// A connection being created or edited in the form.
struct ConnectionDraft: Identifiable {
    var config: ConnectionConfig
    var password: String
    var isNew: Bool
    var id: UUID { config.id }

    static func new(driver: DriverKind = .postgres) -> ConnectionDraft {
        var c = ConnectionConfig(name: "", driver: driver)
        if driver == .postgres { c.port = 5432 }
        return ConnectionDraft(config: c, password: "", isNew: true)
    }

    static func edit(_ c: ConnectionConfig) -> ConnectionDraft {
        ConnectionDraft(config: c, password: Keychain.secrets(for: c.id).password ?? "", isNew: false)
    }
}

enum ConnectionSort: String, CaseIterable {
    case name = "Name", recent = "Recently Used", driver = "Driver", environment = "Environment"
}

@MainActor
@Observable
final class WelcomeModel {
    var connections: [ConnectionConfig] = []
    var groups: [ConnectionGroup] = []
    var search = ""
    /// Environment chip under the search field; nil = all.
    var environmentFilter: ConnectionEnvironment?
    var selection: UUID?
    var editing: ConnectionDraft?
    var connectingID: UUID?
    var errorMessage: String?
    var sort: ConnectionSort {
        didSet { UserDefaults.standard.set(sort.rawValue, forKey: "welcomeSort") }
    }
    @ObservationIgnored private var observer: Any?

    init() {
        sort = ConnectionSort(rawValue: UserDefaults.standard.string(forKey: "welcomeSort") ?? "") ?? .name
        reload()
        observer = NotificationCenter.default.addObserver(forName: .mtpConnectionsDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func reload() {
        connections = ConnectionStore.shared.connections
        groups = ConnectionStore.shared.groups
    }

    var tablePlusAvailable: Bool { TablePlusImporter().isAvailable }

    struct Section: Identifiable {
        var id: String
        var title: String
        var group: ConnectionGroup?
        var items: [ConnectionConfig]
    }

    var sections: [Section] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = connections.filter { c in
            (environmentFilter == nil || c.environment == environmentFilter) && (q.isEmpty || c.name.lowercased().contains(q) || c.host.lowercased().contains(q) || c.database.lowercased().contains(q)
                || c.environment.rawValue.contains(q) || c.filePath.lowercased().contains(q))
        }
        let sorted = filtered.sorted { a, b in
            switch sort {
            case .name: return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case .recent: return (a.lastConnectedAt ?? .distantPast) > (b.lastConnectedAt ?? .distantPast)
            case .driver: return (a.driver.rawValue, a.name) < (b.driver.rawValue, b.name)
            case .environment:
                let order = ConnectionEnvironment.allCases
                return (order.firstIndex(of: b.environment)!, a.name) < (order.firstIndex(of: a.environment)!, b.name)
            }
        }
        var out: [Section] = []
        for g in groups.sorted(by: { $0.name < $1.name }) {
            let items = sorted.filter { $0.groupID == g.id }
            if !items.isEmpty || (q.isEmpty && environmentFilter == nil) { out.append(Section(id: g.id.uuidString, title: g.name, group: g, items: items)) }
        }
        let loose = sorted.filter { c in c.groupID == nil || !groups.contains { $0.id == c.groupID } }
        if !loose.isEmpty { out.append(Section(id: "ungrouped", title: groups.isEmpty ? "Connections" : "Other", group: nil, items: loose)) }
        return out
    }

    func connect(_ id: UUID) {
        guard let c = connections.first(where: { $0.id == id }) else { return }
        AppDelegate.shared.openWorkspace(c)
        AppDelegate.shared.closeWelcome()
    }

    func duplicate(_ id: UUID) {
        guard var c = connections.first(where: { $0.id == id }) else { return }
        let secrets = Keychain.secrets(for: c.id)
        c.id = UUID()
        c.name += " copy"
        c.tablePlusID = nil
        c.createdAt = Date()
        ConnectionStore.shared.upsert(c, secrets: secrets)
        selection = c.id
    }

    func delete(_ id: UUID) {
        guard let c = connections.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(c.name)”?"
        alert.informativeText = "The connection and its saved password are removed. Query history is kept."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn { ConnectionStore.shared.delete(id) }
    }

    func copyURL(_ id: UUID) {
        guard let c = connections.first(where: { $0.id == id }) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ConnectionURL.make(c, password: nil), forType: .string)
    }

    func move(_ id: UUID, to group: UUID?) {
        guard var c = connections.first(where: { $0.id == id }) else { return }
        c.groupID = group
        ConnectionStore.shared.upsert(c)
    }

    func newGroup() {
        let alert = NSAlert()
        alert.messageText = "New Group"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Group name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
        ConnectionStore.shared.upsertGroup(ConnectionGroup(name: field.stringValue))
    }

    func renameGroup(_ g: ConnectionGroup) {
        let alert = NSAlert()
        alert.messageText = "Rename Group"
        let field = NSTextField(string: g.name)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
        var g = g
        g.name = field.stringValue
        ConnectionStore.shared.upsertGroup(g)
    }

    func deleteGroup(_ g: ConnectionGroup) {
        ConnectionStore.shared.deleteGroup(g.id)
    }

    func openSQLiteFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.database, .init(filenameExtension: "sqlite")!, .init(filenameExtension: "db")!, .init(filenameExtension: "sqlite3")!]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        AppDelegate.shared.open(url)
        AppDelegate.shared.closeWelcome()
    }
}
