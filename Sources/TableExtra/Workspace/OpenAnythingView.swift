import AppKit
import MTPCore
import MTPUIKit
import SwiftUI

/// ⌘P Open Anything (tables, views, functions, favorites, history), ⌥⌘P command palette,
/// ⌘K database switcher and ⌥⌘K schema switcher — one fuzzy palette.
struct OpenAnythingView: View {
    var model: WorkspaceModel
    var mode: WorkspaceOverlay
    @State private var query = ""
    @State private var selected = 0
    @State private var otherSchemaObjects: [DBObject] = []
    @State private var scope: Scope = .all

    /// Result filter chips under the search field (Open Anything only). Tab cycles through them.
    enum Scope: String, CaseIterable {
        case all = "All", tables = "Tables", views = "Views", functions = "Functions", favorites = "Favorites", history = "History"
    }
    @FocusState private var focused: Bool

    struct Item: Identifiable {
        let id: String
        var title: String
        var subtitle: String
        var icon: String
        var scope: Scope = .all
        var action: @MainActor () -> Void
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
                TextField(placeholder, text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18))
                    .focused($focused)
                    .onSubmit { run(selected) }
                    .onKeyPress(.downArrow) { selected = min(selected + 1, max(0, items.count - 1)); return .handled }
                    .onKeyPress(.upArrow) { selected = max(selected - 1, 0); return .handled }
                    .onKeyPress(.escape) { model.overlay = nil; return .handled }
                    .onKeyPress(.tab) {
                        guard mode == .openAnything else { return .ignored }
                        let all = Scope.allCases
                        scope = all[((all.firstIndex(of: scope) ?? 0) + 1) % all.count]
                        selected = 0
                        return .handled
                    }
            }
            .padding(.horizontal, DS.Space.xl)
            .frame(height: 52)
            if mode == .openAnything {
                HStack(spacing: DS.Space.xs) {
                    ForEach(Scope.allCases, id: \.self) { s in
                        Text(s.rawValue)
                            .font(.system(size: 11.5, weight: scope == s ? .semibold : .regular))
                            .foregroundStyle(scope == s ? Color.accentColor : Color.secondary)
                            .padding(.horizontal, 9)
                            .frame(height: 22)
                            .background(Capsule().fill(scope == s ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05)))
                            .contentShape(Capsule())
                            .onTapGesture { scope = s; selected = 0 }
                    }
                    Spacer()
                    Text("⇥ to switch").font(DS.Typo.caption).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, DS.Space.l)
                .padding(.bottom, DS.Space.m)
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(items.prefix(60).enumerated()), id: \.element.id) { i, item in
                            let on = i == selected
                            HStack(spacing: DS.Space.l) {
                                Image(systemName: item.icon)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(on ? Color.accentColor : Color.secondary)
                                    .frame(width: 26, height: 26)
                                    .background(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).fill(Color.primary.opacity(on ? 0.0 : 0.05)))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.title).font(DS.Typo.body).lineLimit(1)
                                    if !item.subtitle.isEmpty {
                                        Text(item.subtitle).font(DS.Typo.caption).lineLimit(1).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                                if on { KeyCap("↩") }
                            }
                            .padding(.horizontal, DS.Space.m)
                            .frame(height: 42)
                            .background(RoundedRectangle(cornerRadius: DS.Radius.l - 2, style: .continuous).fill(on ? Color.accentColor.opacity(0.14) : .clear))
                            .contentShape(Rectangle())
                            .onTapGesture { run(i) }
                            .onHover { if $0 { selected = i } }
                            .id(i)
                        }
                    }
                    .padding(DS.Space.s)
                }
                .frame(maxHeight: 400)
                .onChange(of: selected) { _, s in proxy.scrollTo(s) }
            }
            if items.isEmpty {
                Text("No match").font(DS.Typo.callout).foregroundStyle(.secondary).padding(DS.Space.xl)
            }
            Divider()
            HStack(spacing: DS.Space.l) {
                footerHint("↑↓", "Navigate")
                footerHint("↩", "Open")
                footerHint("esc", "Close")
                Spacer()
                Text("\(items.count) result\(items.count == 1 ? "" : "s")").font(DS.Typo.caption).foregroundStyle(.tertiary).monospacedDigit()
            }
            .padding(.horizontal, DS.Space.l)
            .frame(height: 32)
        }
        .frame(width: 640)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.xl, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.xl, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.22), radius: 30, y: 14)
        .onAppear {
            focused = true
            if mode == .openAnything { Task { await loadOtherSchemas() } }
        }
        .onChange(of: query) { _, _ in selected = 0 }
    }

    private func footerHint(_ keys: String, _ title: String) -> some View {
        HStack(spacing: 5) {
            KeyCap(keys)
            Text(title).font(DS.Typo.caption).foregroundStyle(.secondary)
        }
    }

    private var icon: String {
        switch mode {
        case .openAnything: return "magnifyingglass"
        case .commandPalette: return "command"
        case .databaseSwitcher: return "cylinder"
        case .schemaSwitcher: return "folder"
        }
    }

    private var placeholder: String {
        switch mode {
        case .openAnything: return "Open table, view, function, favorite…"
        case .commandPalette: return "Run a command…"
        case .databaseSwitcher: return "Switch database…"
        case .schemaSwitcher: return "Switch schema…"
        }
    }

    private func run(_ i: Int) {
        guard i < items.count else { return }
        let action = items[i].action
        model.overlay = nil
        action()
    }

    private func loadOtherSchemas() async {
        var out: [DBObject] = []
        for s in model.schemas where s != model.currentSchema {
            if let objs = try? await model.introspector.objects(in: s) { out += objs.filter { $0.kind.hasData } }
            if out.count > 3000 { break }
        }
        otherSchemaObjects = out
    }

    private var items: [Item] {
        let all: [Item]
        switch mode {
        case .openAnything: all = objectItems + favoriteItems + historyItems
        case .commandPalette: all = commandItems
        case .databaseSwitcher:
            all = model.databases.map { db in
                Item(id: "db:\(db)", title: db, subtitle: db == model.currentDatabase ? "current" : "", icon: "cylinder") { [model] in
                    Task { await model.switchDatabase(db) }
                }
            }
        case .schemaSwitcher:
            all = model.schemas.map { s in
                Item(id: "schema:\(s)", title: s, subtitle: s == model.currentSchema ? "current" : "", icon: "folder") { [model] in
                    Task { await model.switchSchema(s) }
                }
            }
        }
        let scoped = mode == .openAnything && scope != .all ? all.filter { $0.scope == scope } : all
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return Array(scoped.prefix(200)) }
        return scoped.compactMap { item -> (Item, Int)? in
            guard let score = Self.score(q, item.title.lowercased()) else { return nil }
            return (item, score)
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }

    /// Higher is better; nil = no match. Prefix > word start > substring > subsequence.
    static func score(_ q: String, _ s: String) -> Int? {
        if s == q { return 1000 }
        if s.hasPrefix(q) { return 800 - s.count }
        if s.contains("_" + q) || s.contains("." + q) || s.contains(" " + q) { return 600 - s.count }
        if s.contains(q) { return 400 - s.count }
        var it = s.makeIterator()
        for ch in q {
            var found = false
            while let c = it.next() { if c == ch { found = true; break } }
            if !found { return nil }
        }
        return 100 - s.count
    }

    private var objectItems: [Item] {
        (model.objects + otherSchemaObjects).map { o in
            Item(id: "obj:\(o.id)", title: o.kind == .function || o.kind == .procedure ? (o.signature ?? o.name) : o.name,
                 subtitle: "\(o.kind.sectionTitle.dropLast()) · \(o.schema)\(o.estimatedRows.map { " · \(Fmt.compact($0)) row\($0 == 1 ? "" : "s")" } ?? "")",
                 icon: o.kind.symbolName, scope: Self.scope(for: o.kind)) { [model] in
                if o.schema != model.currentSchema, o.kind.hasData {
                    model.openTable(schema: o.schema, name: o.name)
                } else {
                    model.openObject(o, pin: true)
                }
            }
        }
    }

    private var favoriteItems: [Item] {
        FavoritesStore.shared.all(for: model.connection.id).map { f in
            Item(id: "fav:\(f.id)", title: f.name, subtitle: "Favorite · " + f.sql.prefix(80).replacingOccurrences(of: "\n", with: " "), icon: "star", scope: .favorites) { [model] in
                model.openQueryTab(title: f.name, sql: f.sql, run: false)
            }
        }
    }

    static func scope(for kind: DBObjectKind) -> Scope {
        switch kind {
        case .table: return .tables
        case .view, .materializedView: return .views
        case .function, .procedure: return .functions
        default: return .all
        }
    }

    private var historyItems: [Item] {
        guard query.count >= 2 || scope == .history else { return [] }
        return HistoryStore.shared.entries(connectionID: model.connection.id, search: query, limit: 30).map { e in
            Item(id: "hist:\(e.id)", title: e.sql.replacingOccurrences(of: "\n", with: " ").prefix(90).description,
                 subtitle: "History · \(Fmt.relative(e.executedAt))", icon: "clock", scope: .history) { [model] in
                model.openQueryTab(title: "History", sql: e.sql, run: false)
            }
        }
    }

    private var commandItems: [Item] {
        let send: (Selector) -> @MainActor () -> Void = { sel in { NSApp.sendAction(sel, to: nil, from: nil) } }
        let commands: [(String, String, Selector)] = [
            ("New Query Tab", "terminal", #selector(MTPActions.newQueryTab(_:))),
            ("Ask AI (Claude)", "sparkles", #selector(MTPActions.showAIAssistant(_:))),
            ("Database Insights", "gauge.with.dots.needle.67percent", #selector(MTPActions.showInsights(_:))),
            ("AWS RDS Monitoring", "cloud", #selector(MTPActions.showRDS(_:))),
            ("Process List", "list.bullet.rectangle", #selector(MTPActions.showProcessList(_:))),
            ("ER Diagram", "point.3.connected.trianglepath.dotted", #selector(MTPActions.showDiagram(_:))),
            ("Schema Diff", "arrow.left.arrow.right.square", #selector(MTPActions.showSchemaDiff(_:))),
            ("Generate Kysely / TypeScript Types", "curlybraces.square", #selector(MTPActions.generateTypeScript(_:))),
            ("Search in Database", "magnifyingglass", #selector(MTPActions.searchInDatabase(_:))),
            ("Export…", "square.and.arrow.up", #selector(MTPActions.exportData(_:))),
            ("Import CSV…", "square.and.arrow.down", #selector(MTPActions.importCSV(_:))),
            ("Backup Database…", "externaldrive.badge.timemachine", #selector(MTPActions.backupDatabase(_:))),
            ("Restore Database…", "arrow.counterclockwise", #selector(MTPActions.restoreDatabase(_:))),
            ("Switch Database", "cylinder", #selector(MTPActions.switchDatabase(_:))),
            ("Switch Schema", "folder", #selector(MTPActions.switchSchema(_:))),
            ("Reload Workspace", "arrow.clockwise", #selector(MTPActions.reloadWorkspace(_:))),
            ("Reconnect", "bolt.horizontal", #selector(MTPActions.reconnect(_:))),
            ("Edit Connection", "slider.horizontal.3", #selector(MTPActions.editCurrentConnection(_:))),
            ("Toggle Console Log", "terminal", #selector(MTPActions.toggleConsole(_:))),
            ("Toggle Right Sidebar", "sidebar.right", #selector(MTPActions.toggleRightSidebar(_:))),
            ("Query History", "clock.arrow.circlepath", #selector(MTPActions.showHistory(_:))),
            ("Favorites", "star", #selector(MTPActions.showFavorites(_:))),
            ("Settings", "gearshape", #selector(MTPActions.showSettings(_:))),
            ("Import Connections from TablePlus", "square.and.arrow.down.on.square", #selector(MTPActions.importFromTablePlus(_:))),
        ]
        return commands.map { title, icon, sel in Item(id: "cmd:\(title)", title: title, subtitle: "", icon: icon, action: send(sel)) }
    }
}

/// Find a value in every text-like column of every table of the schema (TablePlus "Search in Database").
struct DatabaseSearchView: View {
    var model: WorkspaceModel
    @State private var term = ""
    @State private var exact = false
    @State private var hits: [(table: String, column: String, count: Int64)] = []
    @State private var running = false
    @State private var progress = ""
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Value to find in \(model.currentSchema)…", text: $term).textFieldStyle(.roundedBorder).onSubmit(start)
                Toggle("Exact match", isOn: $exact)
                if running {
                    Button("Stop") { task?.cancel(); running = false }
                } else {
                    Button("Search", action: start).buttonStyle(.borderedProminent).disabled(term.isEmpty)
                }
            }
            if running || !progress.isEmpty { Text(progress).font(.caption).foregroundStyle(.secondary) }
            List(hits, id: \.column) { h in
                HStack {
                    Image(systemName: "tablecells").foregroundStyle(.blue)
                    Text(h.table).fontWeight(.medium)
                    Text(".\(h.column)").foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Fmt.count(h.count)) row\(h.count == 1 ? "" : "s")").monospacedDigit()
                    Button("Open") {
                        model.openTable(schema: model.currentSchema, name: h.table,
                                        filter: FilterRule(column: h.column, op: exact ? .equals : .containsCaseInsensitive, value: term))
                    }
                }
            }
        }
        .padding(14)
    }

    private func start() {
        guard !term.isEmpty else { return }
        hits = []
        running = true
        let term = term, exact = exact
        let client = model.makeClient(label: "search")
        let dialect = model.dialect
        let schema = model.currentSchema
        let tables = model.columnsByTable
        task = Task {
            defer { client.close() }
            var done = 0
            for (table, cols) in tables.sorted(by: { $0.key < $1.key }) {
                if Task.isCancelled { break }
                done += 1
                progress = "Searching \(table) (\(done)/\(tables.count))…"
                let textCols = cols.filter { [.text, .json, .uuid, .enumeration, .other].contains($0.kind) || $0.kind == .integer && Int64(term) != nil }
                for c in textCols {
                    let col = dialect.quoteIdent(c.name)
                    let cond = exact ? "\(dialect.castToText(col)) = \(dialect.placeholder(1))"
                                     : "\(dialect.castToText(col)) \(dialect.caseInsensitiveLike) \(dialect.placeholder(1))"
                    let sql = "SELECT count(*) FROM \(dialect.qualified(schema: schema, name: table)) WHERE \(cond)"
                    if let r = try? await client.query(sql, [exact ? term : "%\(term)%"]), let n = Int64(r.rows.first?[0] ?? "0"), n > 0 {
                        hits.append((table, c.name, n))
                    }
                }
            }
            progress = "\(hits.count) column\(hits.count == 1 ? "" : "s") contain “\(term)”"
            running = false
        }
    }
}
