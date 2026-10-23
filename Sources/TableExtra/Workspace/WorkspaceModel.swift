import AppKit
import FeatureAI
import MTPCore
import MTPUIKit
import Observation

enum ConnectionStatus: Equatable {
    case connecting
    case connected
    case failed(String)
    case disconnected
}

enum SidebarMode: String, CaseIterable {
    case items = "Items", favorites = "Queries", history = "History"
}

enum WorkspaceOverlay: Equatable {
    case openAnything
    case commandPalette
    case databaseSwitcher
    case schemaSwitcher
}

/// One workspace window = one connection. Implements the WorkspaceContext used by feature modules.
@MainActor
@Observable
final class WorkspaceModel: WorkspaceContext {
    private(set) var connection: ConnectionConfig
    @ObservationIgnored let secrets: ConnectionSecrets
    private(set) var client: DBClient
    private(set) var introspector: SchemaIntrospector
    var serverInfo: ServerInfo?
    var currentDatabase: String
    var currentSchema: String
    var schemas: [String] = []
    var databases: [String] = []
    var objects: [DBObject] = []
    var objectsLoading = false
    /// table → columns of the current schema, for autocomplete and AI context.
    var columnsByTable: [String: [ColumnDef]] = [:]
    var status: ConnectionStatus = .connecting

    var tabs: [WorkspaceTab] = []
    var selectedTabID: UUID? {
        didSet { assistant.bridge = selectedTab as? QueryTabModel }
    }
    /// What the right inspector shows: the Claude conversation or, for table tabs, the selected row.
    enum InspectorMode: Hashable { case claude, row }
    var inspectorMode: InspectorMode = .claude
    /// The window's Claude conversation, shared by every screen (see `askClaude`).
    @ObservationIgnored lazy var assistant = AIAssistantModel(context: self)
    var sidebarFilter = ""
    var sidebarMode: SidebarMode = .items
    var showLeftSidebar = true
    /// Window width, kept up to date by the window controller; sizes the toolbar context bar.
    var windowWidth: CGFloat = 1320
    var showRightSidebar = false
    var showConsole = false
    var overlay: WorkspaceOverlay?
    var sheet: WorkspaceSheet?
    var toast: String?
    var console: [ConsoleEntry] = []
    var collapsedSections: Set<DBObjectKind> = [.function, .procedure, .sequence, .type]
    /// Sidebar group nodes (prefix folders, date series) the user opened.
    var expandedGroups: Set<String> = []
    /// Group long table lists by name prefix (persisted).
    var groupByPrefix: Bool = UserDefaults.standard.object(forKey: "sidebar.groupByPrefix") as? Bool ?? true {
        didSet { UserDefaults.standard.set(groupByPrefix, forKey: "sidebar.groupByPrefix") }
    }
    /// Objects pinned to the top of the sidebar, per connection (DBObject ids).
    var pinned: [String] = [] {
        didSet { UserDefaults.standard.set(pinned, forKey: "sidebar.pinned.\(connection.id.uuidString)") }
    }

    func isPinned(_ obj: DBObject) -> Bool { pinned.contains(obj.id) }

    func togglePin(_ obj: DBObject) {
        if let i = pinned.firstIndex(of: obj.id) { pinned.remove(at: i) } else { pinned.append(obj.id) }
    }

    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private var backStack: [UUID] = []
    @ObservationIgnored private var forwardStack: [UUID] = []
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var restoreState: WorkspaceSession.State?

    init(config: ConnectionConfig, secrets: ConnectionSecrets, state: WorkspaceSession.State? = nil) {
        self.connection = config
        self.secrets = secrets
        var cfg = config
        if let db = state?.database, !db.isEmpty, config.driver == .postgres { cfg.database = db }
        let client = DBClient(config: cfg, secrets: secrets)
        self.client = client
        self.introspector = Introspection.make(client)
        self.currentDatabase = cfg.driver == .sqlite ? (cfg.filePath as NSString).lastPathComponent : cfg.database
        self.currentSchema = state?.schema ?? cfg.defaultSchema ?? (cfg.driver == .sqlite ? "main" : "public")
        self.restoreState = state
        self.pinned = UserDefaults.standard.stringArray(forKey: "sidebar.pinned.\(config.id.uuidString)") ?? []
    }

    // MARK: Lifecycle

    func connect() async {
        status = .connecting
        do {
            serverInfo = try await client.connect()
            if connection.driver == .postgres, let db = serverInfo?.currentDatabase, !db.isEmpty { currentDatabase = db }
            status = .connected
            schemas = (try? await introspector.schemas(includeSystem: false)) ?? []
            if !schemas.contains(currentSchema) {
                currentSchema = (try? await introspector.defaultSchema()) ?? schemas.first ?? currentSchema
                if !schemas.contains(currentSchema), let first = schemas.first { currentSchema = first }
            }
            await loadObjects()
            if connection.driver == .postgres { databases = (try? await introspector.databases()) ?? [] }
            restoreTabsIfNeeded()
            if UserDefaults.standard.bool(forKey: SettingKey.openInsightsOnConnect) {
                openFeature(.insights)
            } else if tabs.isEmpty, objects.isEmpty {
                openQueryTab(title: nil, sql: "", run: false)
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func loadObjects() async {
        objectsLoading = true
        defer { objectsLoading = false }
        do {
            objects = try await introspector.objects(in: currentSchema)
        } catch {
            showError(error)
            objects = []
        }
        columnsByTable = (try? await introspector.columnsByTable(schema: currentSchema)) ?? [:]
    }

    func disconnect() {
        for tab in tabs { (tab as? QueryTabModel)?.close() }
        client.close()
        status = .disconnected
    }

    func reconnect() async {
        client.close()
        rebuildClient(database: currentDatabase)
        await connect()
        for tab in tabs { (tab as? QueryTabModel)?.resetSession() }
    }

    private func rebuildClient(database: String) {
        var cfg = connection
        if connection.driver == .postgres { cfg.database = database }
        client = DBClient(config: cfg, secrets: secrets)
        introspector = Introspection.make(client)
    }

    func switchDatabase(_ db: String) async {
        guard db != currentDatabase, connection.driver == .postgres else { return }
        if hasUnsavedChanges, !confirmDiscard() { return }
        for tab in tabs { (tab as? QueryTabModel)?.close() }
        client.close()
        tabs.removeAll()
        selectedTabID = nil
        currentDatabase = db
        currentSchema = "public"
        rebuildClient(database: db)
        await connect()
    }

    func switchSchema(_ schema: String) async {
        guard schema != currentSchema else { return }
        currentSchema = schema
        await loadObjects()
    }

    func reloadWorkspace() async {
        schemas = (try? await introspector.schemas(includeSystem: false)) ?? schemas
        await loadObjects()
        if let t = selectedTab as? TableTabModel { await t.reloadAll() }
        showToast("Reloaded")
    }

    var hasUnsavedChanges: Bool { tabs.contains { $0.hasUnsavedChanges } }

    func updateConnection(_ c: ConnectionConfig) {
        connection = c
        ConnectionStore.shared.upsert(c)
    }

    // MARK: Tabs

    var selectedTab: WorkspaceTab? { tabs.first { $0.id == selectedTabID } }

    func select(_ id: UUID?, recordHistory: Bool = true) {
        if recordHistory, let current = selectedTabID, current != id {
            backStack.append(current)
            forwardStack.removeAll()
        }
        selectedTabID = id
    }

    func add(_ tab: WorkspaceTab, replacePreview: Bool = false) {
        if replacePreview, let i = tabs.firstIndex(where: { $0.isPreview && !$0.hasUnsavedChanges }) {
            (tabs[i] as? QueryTabModel)?.close()
            tabs[i] = tab
        } else if let current = selectedTabID, let i = tabs.firstIndex(where: { $0.id == current }) {
            tabs.insert(tab, at: i + 1)
        } else {
            tabs.append(tab)
        }
        select(tab.id)
    }

    func closeTab(_ id: UUID) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[i]
        if tab.hasUnsavedChanges {
            let alert = NSAlert()
            alert.messageText = "Close “\(tab.title)” and discard its changes?"
            alert.addButton(withTitle: "Discard")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        (tab as? QueryTabModel)?.close()
        tabs.remove(at: i)
        backStack.removeAll { $0 == id }
        if selectedTabID == id {
            let next = backStack.popLast().flatMap { b in tabs.contains { $0.id == b } ? b : nil }
            selectedTabID = next ?? (tabs.isEmpty ? nil : tabs[min(i, tabs.count - 1)].id)
        }
    }

    func selectNextTab(_ delta: Int) {
        guard !tabs.isEmpty else { return }
        let i = tabs.firstIndex { $0.id == selectedTabID } ?? 0
        select(tabs[(i + delta + tabs.count) % tabs.count].id)
    }

    func goBack() {
        guard let prev = backStack.popLast(), tabs.contains(where: { $0.id == prev }) else { return }
        if let cur = selectedTabID { forwardStack.append(cur) }
        select(prev, recordHistory: false)
    }

    func goForward() {
        guard let next = forwardStack.popLast(), tabs.contains(where: { $0.id == next }) else { return }
        if let cur = selectedTabID { backStack.append(cur) }
        select(next, recordHistory: false)
    }

    /// Single click in the sidebar opens a preview tab; double click (pin) opens a permanent one.
    func openObject(_ object: DBObject, pin: Bool, mode: TableTabMode = .data, filter: FilterRule? = nil) {
        if !object.kind.hasData {
            Task { await openDefinition(object) }
            return
        }
        if filter == nil, let existing = tabs.compactMap({ $0 as? TableTabModel }).first(where: { $0.object.id == object.id }) {
            if pin { existing.isPreview = false }
            existing.mode = mode
            select(existing.id)
            return
        }
        let tab = TableTabModel(workspace: self, object: object, mode: mode)
        tab.isPreview = !pin && filter == nil
        if let filter {
            tab.filters = [filter]
            tab.showFilters = true
        }
        add(tab, replacePreview: !pin)
        Task { await tab.reloadAll() }
    }

    func openTable(schema: String, name: String) {
        openTable(schema: schema, name: name, filter: nil)
    }

    func openTable(schema: String, name: String, filter: FilterRule?) {
        let obj = objects.first { $0.schema == schema && $0.name == name && $0.kind.hasData } ?? DBObject(schema: schema, name: name, kind: .table)
        openObject(obj, pin: true, filter: filter)
    }

    func openDefinition(_ object: DBObject) async {
        do {
            let ddl = try await introspector.ddl(for: object)
            openQueryTab(title: object.name, sql: ddl, run: false)
        } catch {
            showError(error)
        }
    }

    func openQueryTab(title: String?, sql: String, run: Bool) {
        openQueryTab(title: title, sql: sql, run: run, fileURL: nil)
    }

    func openQueryTab(title: String?, sql: String, run: Bool, fileURL: URL?) {
        let n = tabs.filter { $0 is QueryTabModel }.count + 1
        let tab = QueryTabModel(workspace: self, title: title ?? "Query \(n)", sql: sql)
        tab.fileURL = fileURL
        add(tab)
        if run { Task { await tab.runAll() } }
    }

    func openFeature(_ kind: FeatureKind) {
        if let existing = tabs.compactMap({ $0 as? FeatureTabModel }).first(where: { $0.kind == kind }) {
            select(existing.id)
            return
        }
        add(FeatureTabModel(kind: kind))
    }

    func refreshSidebar() {
        Task { await loadObjects() }
    }

    // MARK: WorkspaceContext

    func makeClient(label: String) -> DBClient { client.makeSibling(label: label) }

    func confirmWrite(sql: String, summary: String) async -> Bool {
        await confirmWrite(statements: StatementSplitter.split(sql).map(\.text), summary: summary, rehearseOn: nil)
    }

    /// Full gate: optional dry run (PostgreSQL), confirmation, Touch ID, read-only refusal.
    func confirmWrite(statements: [String], summary: String, rehearseOn rehearsal: DBClient?) async -> Bool {
        let config = connection
        if config.safety == .readOnly || SafetyGate.needsConfirmation(statements, config: config) {
            var request = SafetyGate.Request(statements: statements, summary: summary)
            if config.dryRunWrites, config.safety != .readOnly, statements.count == 1,
               QueryClassifier.analyze(statements[0], driver: config.driver).supportsDryRun {
                let target = rehearsal ?? client
                if !target.inTransaction {
                    do {
                        let r = try await target.dryRun(statements[0])
                        request.dryRunRows = r.affectedRows ?? r.rows.count
                    } catch {
                        request.dryRunError = error.localizedDescription
                    }
                }
            }
            return await SafetyGate.confirm(request, config: config, window: window)
        }
        return true
    }

    func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = (error as? DatabaseError)?.fullMessage ?? error.localizedDescription
        alert.alertStyle = .warning
        if let window, window.isVisible { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    func askClaude(_ request: AIRequest) {
        assistant.bridge = selectedTab as? QueryTabModel
        inspectorMode = .claude
        showRightSidebar = true
        assistant.ask(request)
    }

    /// Opens or closes the Claude panel (toolbar button, ⌘L).
    func toggleClaude() {
        if showRightSidebar && inspectorMode == .claude {
            showRightSidebar = false
        } else {
            assistant.bridge = selectedTab as? QueryTabModel
            inspectorMode = .claude
            showRightSidebar = true
        }
    }

    var isClaudeOpen: Bool { showRightSidebar && inspectorMode == .claude }

    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    func log(sql: String, duration: TimeInterval, outcome: String, isError: Bool, source: String) {
        console.append(ConsoleEntry(sql: sql, duration: duration, outcome: outcome, isError: isError))
        if console.count > 2000 { console.removeFirst(console.count - 2000) }
        HistoryStore.shared.add(connectionID: connection.id, database: currentDatabase, sql: sql, duration: duration,
                                rowCount: nil, error: isError ? outcome : nil, source: source)
    }

    func confirmDiscard() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Discard uncommitted changes?"
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: Session restore

    private func restoreTabsIfNeeded() {
        guard let state = restoreState else { return }
        restoreState = nil
        for t in state.tabs {
            switch t.kind {
            case "table":
                if let obj = objects.first(where: { $0.schema == t.schema && $0.name == t.name && $0.kind.hasData }) ?? (t.name.map { DBObject(schema: t.schema ?? currentSchema, name: $0, kind: .table) }) {
                    let tab = TableTabModel(workspace: self, object: obj, mode: t.mode == "structure" ? .structure : .data)
                    tab.isPreview = false
                    tabs.append(tab)
                    Task { await tab.reloadAll() }
                }
            case "query":
                let tab = QueryTabModel(workspace: self, title: t.title ?? "Query", sql: t.sql ?? "")
                tab.fileURL = t.file.map { URL(fileURLWithPath: $0) }
                tabs.append(tab)
            default:
                break
            }
        }
        selectedTabID = tabs.indices.contains(state.selectedIndex ?? -1) ? tabs[state.selectedIndex!].id : tabs.first?.id
    }
}
