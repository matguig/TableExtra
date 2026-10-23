import AppKit
import MTPCore
import MTPUIKit
import SwiftUI

struct SidebarView: View {
    @Bindable var model: WorkspaceModel
    @FocusState private var searchFocused: Bool
    @State private var selection: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.s) {
                CompactSegmented(SidebarMode.allCases.map { (label: $0.rawValue, value: $0) }, selection: $model.sidebarMode)
                Spacer(minLength: 0)
                if model.objectsLoading { ProgressView().controlSize(.mini) }
                Button { model.refreshSidebar() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .medium)) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Refresh")
                if model.sidebarMode == .items { optionsMenu }
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.top, DS.Space.xs)
            .padding(.bottom, DS.Space.s)
            filterField
                .padding(.horizontal, DS.Space.m)
                .padding(.bottom, DS.Space.s)
            switch model.sidebarMode {
            case .items: itemsList
            case .favorites: FavoritesListView(model: model, compact: true)
            case .history: HistoryListView(model: model, compact: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .mtpFocusSidebarSearch)) { n in
            if (n.object as AnyObject?) === model { searchFocused = true }
        }
        // SwiftUI gives the first text field focus when the window opens; keyboard input belongs to the grid/editor.
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { searchFocused = false } }
    }

    private var filterField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.tertiary)
            TextField(model.sidebarMode == .items ? "Filter tables, views…" : "Search", text: $model.sidebarFilter)
                .textFieldStyle(.plain)
                .font(DS.Typo.callout)
                .focused($searchFocused)
            if !model.sidebarFilter.isEmpty {
                Button { model.sidebarFilter = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).fill(Color.primary.opacity(0.055)))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
            .strokeBorder(searchFocused ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1))
    }

    private var filtered: [DBObject] {
        let q = model.sidebarFilter.lowercased()
        guard !q.isEmpty else { return model.objects }
        return model.objects.filter { Self.fuzzy(q, $0.name.lowercased()) }
    }

    /// Characters of the query appear in order ("oi" matches "order_items").
    static func fuzzy(_ q: String, _ s: String) -> Bool {
        if s.contains(q) { return true }
        var it = s.makeIterator()
        for ch in q {
            var found = false
            while let c = it.next() { if c == ch { found = true; break } }
            if !found { return false }
        }
        return true
    }

    /// Pinned rows use a distinct tag so the same object can also appear in its section.
    private static let pinTag = "pin:"

    private func object(forTag tag: String) -> DBObject? {
        let id = tag.hasPrefix(Self.pinTag) ? String(tag.dropFirst(Self.pinTag.count)) : tag
        return model.objects.first { $0.id == id }
    }

    private var pinnedObjects: [DBObject] {
        model.pinned.compactMap { id in model.objects.first { $0.id == id } }
    }

    private var itemsList: some View {
        let query = model.sidebarFilter.lowercased()
        return List(selection: $selection) {
            if query.isEmpty, !pinnedObjects.isEmpty {
                Section {
                    ForEach(pinnedObjects) { obj in
                        SidebarRow(object: obj, display: obj.schema == model.currentSchema ? obj.name : obj.qualifiedName,
                                   query: "", pinned: true, togglePin: { model.togglePin(obj) })
                            .tag(Self.pinTag + obj.id)
                    }
                } header: {
                    SidebarSectionHeader(title: "Pinned", count: pinnedObjects.count)
                }
            }
            ForEach(DBObjectKind.allCases, id: \.self) { kind in
                let items = filtered.filter { $0.kind == kind }
                if !items.isEmpty {
                    Section(isExpanded: Binding(
                        get: { !model.collapsedSections.contains(kind) || !query.isEmpty },
                        set: { expanded in if expanded { model.collapsedSections.remove(kind) } else { model.collapsedSections.insert(kind) } })
                    ) {
                        ForEach(ObjectGrouping.nodes(for: items, prefixFolders: model.groupByPrefix)) { node in
                            nodeView(node, query: query)
                        }
                    } header: {
                        SidebarSectionHeader(title: kind.sectionTitle, count: items.count)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: selection) { _, tag in
            if let tag, let obj = object(forTag: tag), obj.kind.hasData {
                model.openObject(obj, pin: false)
            }
        }
        .contextMenu(forSelectionType: String.self) { tags in
            if let tag = tags.first, let obj = object(forTag: tag) {
                objectMenu(obj)
            } else {
                Button("New Query") { model.openQueryTab(title: nil, sql: "", run: false) }
                Button("Refresh") { model.refreshSidebar() }
            }
        } primaryAction: { tags in
            if let tag = tags.first, let obj = object(forTag: tag) { model.openObject(obj, pin: true) }
        }
    }

    /// One node of the grouped tree: an object row, or a disclosure group (prefix folder / date series).
    private func nodeView(_ node: ObjectGrouping.Node, query: String) -> AnyView {
        switch node {
        case .object(let obj, let display):
            return AnyView(
                SidebarRow(object: obj, display: display, query: query, pinned: model.isPinned(obj), togglePin: { model.togglePin(obj) })
                    .tag(obj.id)
            )
        case .group(let id, let title, let kind, let children):
            return AnyView(
                DisclosureGroup(isExpanded: Binding(
                    get: { model.expandedGroups.contains(id) || !query.isEmpty },
                    set: { open in if open { model.expandedGroups.insert(id) } else { model.expandedGroups.remove(id) } })
                ) {
                    ForEach(children) { child in nodeView(child, query: query) }
                } label: {
                    SidebarGroupRow(title: title, kind: kind, count: node.objectCount, rows: node.estimatedRows)
                }
            )
        }
    }

    private var optionsMenu: some View {
        Menu {
            Toggle("Group Tables by Name Prefix", isOn: $model.groupByPrefix)
            Divider()
            Button("Expand All Groups") { model.expandedGroups = allGroupIDs }
            Button("Collapse All Groups") { model.expandedGroups = [] }
            if !model.pinned.isEmpty {
                Divider()
                Button("Unpin All") { model.pinned = [] }
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 11, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help("Sidebar options")
    }

    private var allGroupIDs: Set<String> {
        var ids = Set<String>()
        func walk(_ n: ObjectGrouping.Node) {
            if case .group(let id, _, _, let children) = n { ids.insert(id); children.forEach(walk) }
        }
        for kind in DBObjectKind.allCases {
            ObjectGrouping.nodes(for: model.objects.filter { $0.kind == kind }, prefixFolders: model.groupByPrefix).forEach(walk)
        }
        return ids
    }

    @ViewBuilder
    private func objectMenu(_ obj: DBObject) -> some View {
        let q = model.dialect.qualified(schema: obj.schema, name: obj.name)
        if obj.kind.hasData {
            Button("Open in New Tab") { model.openObject(obj, pin: true) }
            Button("Open Structure") { model.openObject(obj, pin: true, mode: .structure) }
            Button("New Query: SELECT *") { model.openQueryTab(title: obj.name, sql: "SELECT *\nFROM \(q)\nLIMIT 100;", run: true) }
        } else {
            Button("Show Definition") { Task { await model.openDefinition(obj) } }
        }
        Button(model.isPinned(obj) ? "Unpin" : "Pin to Top") { model.togglePin(obj) }
        Button("Ask Claude About \(obj.name)…") {
            let repoHint = model.connection.codeRepositoryURL != nil ? " Look up where the application code uses it and cite files." : ""
            model.askClaude(AIRequest(title: "About \(obj.name)",
                                      prompt: "Explain what \(obj.qualifiedName) (\(obj.kind.rawValue)) is for and how it relates to the rest of the schema.\(repoHint)",
                                      focus: obj.name))
        }
        Divider()
        Button("Copy Name") { Pasteboard.copy(obj.name) }
        Button("Copy Qualified Name") { Pasteboard.copy(q) }
        Button("Copy DDL") {
            Task { if let ddl = try? await model.introspector.ddl(for: obj) { Pasteboard.copy(ddl); model.showToast("DDL copied") } }
        }
        if obj.kind == .table || obj.kind == .view || obj.kind == .materializedView {
            Divider()
            Button("Kysely / TypeScript Type…") { model.openFeature(.typeScript(schema: obj.schema, tables: [obj.name])) }
            Button("Export…") { model.sheet = .export(.tables(schema: obj.schema, names: [obj.name])) }
            if obj.kind == .table {
                Button("Import CSV…") { model.sheet = .importCSV(schema: obj.schema, table: obj.name) }
            }
            Button("Count Rows") {
                Task {
                    if let n = try? await model.introspector.exactCount(schema: obj.schema, name: obj.name) {
                        model.showToast("\(obj.name): \(Fmt.count(n)) rows")
                    }
                }
            }
        }
        if obj.kind == .materializedView {
            Button("Refresh Materialized View") {
                model.openQueryTab(title: "Refresh \(obj.name)", sql: "REFRESH MATERIALIZED VIEW CONCURRENTLY \(q);", run: false)
            }
        }
        if obj.kind == .table {
            Divider()
            Button("Truncate…") { model.openQueryTab(title: "Truncate \(obj.name)", sql: "TRUNCATE TABLE \(q);", run: false) }
            Button("Drop…") { model.openQueryTab(title: "Drop \(obj.name)", sql: "DROP TABLE \(q);", run: false) }
        }
    }
}

private struct SidebarSectionHeader: View {
    var title: String
    var count: Int

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(count)").font(DS.Typo.micro).monospacedDigit().foregroundStyle(.tertiary)
        }
    }
}

private struct SidebarRow: View {
    var object: DBObject
    var display: String
    var query: String
    var pinned: Bool
    var togglePin: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: object.kind.symbolName)
                .font(.system(size: 11.5))
                .foregroundStyle(iconColor)
                .frame(width: 16)
            highlighted
                .font(DS.Typo.body)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if hover || pinned {
                Button(action: togglePin) {
                    Image(systemName: pinned ? "pin.fill" : "pin").font(.system(size: 10)).rotationEffect(.degrees(45))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(pinned ? Color.accentColor : Color.secondary)
                .help(pinned ? "Unpin" : "Pin to top")
            } else if let n = object.estimatedRows, object.kind.hasData, n > 0 {
                Text(Fmt.compact(n)).font(DS.Typo.micro).foregroundStyle(.tertiary).monospacedDigit()
            }
        }
        .onHover { hover = $0 }
        .help(object.comment.map { "\(object.qualifiedName)\n\($0)" } ?? object.qualifiedName)
    }

    /// The display name with the filter match in bold (Dropbox Dash / Gemini style).
    private var highlighted: Text {
        let base = object.kind == .function || object.kind == .procedure ? (object.signature ?? display) : display
        guard !query.isEmpty, let r = base.range(of: query, options: .caseInsensitive) else { return Text(base) }
        return Text(base[..<r.lowerBound]) + Text(base[r]).bold().foregroundColor(.primary) + Text(base[r.upperBound...])
    }

    private var iconColor: Color {
        switch object.kind {
        case .table: return .accentColor
        case .view, .materializedView: return .teal
        case .function, .procedure: return .orange
        case .sequence: return .purple
        default: return .secondary
        }
    }
}

/// Folder (shared prefix) or stack (date/number series) in the sidebar tree.
private struct SidebarGroupRow: View {
    var title: String
    var kind: ObjectGrouping.GroupKind
    var count: Int
    var rows: Int64?

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: kind == .series ? "square.stack.3d.down.right" : "folder")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(title).font(DS.Typo.body).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Text("\(count)")
                .font(.system(size: 10, weight: .medium)).monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .frame(height: 15)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
                .help(rows.map { "\(count) objects · ~\(Fmt.compact($0)) rows" } ?? "\(count) objects")
        }
    }
}

struct HistoryListView: View {
    var model: WorkspaceModel
    var compact = false
    @State private var entries: [HistoryEntry] = []
    @State private var search = ""
    @State private var allConnections = false
    @State private var status: StatusFilter = .all
    @State private var selection: Int64?

    enum StatusFilter: Hashable { case all, success, failed }

    var body: some View {
        Group {
            if compact { compactList } else { fullTable }
        }
        .onAppear { reload() }
        .onChange(of: search) { _, _ in reload() }
        .onChange(of: model.sidebarFilter) { _, _ in reload() }
        .onChange(of: allConnections) { _, _ in reload() }
        .onChange(of: model.console.count) { _, _ in reload() }
    }

    private var shown: [HistoryEntry] {
        switch status {
        case .all: return entries
        case .success: return entries.filter { $0.error == nil }
        case .failed: return entries.filter { $0.error != nil }
        }
    }

    private var maxDuration: TimeInterval { max(shown.map(\.duration).max() ?? 0, 0.001) }

    // Sidebar: one row per statement with a status dot, two lines of SQL and a meta line.
    private var compactList: some View {
        List(entries) { e in
            HStack(alignment: .top, spacing: DS.Space.s) {
                Circle().fill(e.error == nil ? Color.green : Color.red).frame(width: 6, height: 6).padding(.top, 5)
                VStack(alignment: .leading, spacing: 3) {
                    Text(e.sql.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(DS.Typo.monoSmall)
                        .lineLimit(2)
                    HStack(spacing: 5) {
                        Text(Fmt.relative(e.executedAt))
                        if e.duration > 0 { Text("·"); Text(Fmt.duration(e.duration)).monospacedDigit() }
                        if e.source != "editor" { Text("·"); Text(e.source.uppercased()).font(DS.Typo.micro) }
                    }
                    .font(DS.Typo.micro)
                    .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { model.openQueryTab(title: "History", sql: e.sql, run: false) }
            .contextMenu { menu(e) }
            .help(e.error ?? e.sql)
        }
        .listStyle(.sidebar)
    }

    // Full tab: filter row, then a dense table (When, SQL, Status, Rows, Duration bar, Source).
    private var fullTable: some View {
        VStack(spacing: 0) {
            ToolStrip {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.tertiary)
                    TextField("Search SQL", text: $search).textFieldStyle(.plain).font(DS.Typo.callout)
                }
                .padding(.horizontal, 7)
                .frame(width: 240, height: 24)
                .background(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).fill(Color.primary.opacity(0.055)))
                CompactSegmented([(label: "All", value: StatusFilter.all), (label: "Success", value: .success), (label: "Failed", value: .failed)], selection: $status)
                    .padding(.leading, DS.Space.s)
            } trailing: {
                Toggle("All connections", isOn: $allConnections).toggleStyle(.checkbox).font(DS.Typo.callout).fixedSize()
                ToolButton("Reload", systemImage: "arrow.clockwise") { reload() }
            }
            Table(shown, selection: $selection) {
                TableColumn("When") { e in
                    Text(Fmt.relative(e.executedAt)).font(DS.Typo.callout).foregroundStyle(.secondary)
                        .help(e.executedAt.formatted(date: .abbreviated, time: .standard))
                }
                .width(min: 70, ideal: 90, max: 120)
                TableColumn("SQL") { e in
                    Text(e.sql.replacingOccurrences(of: "\n", with: " ")).font(DS.Typo.mono).lineLimit(1).help(e.sql)
                }
                .width(min: 200, ideal: 460)
                TableColumn("Status") { e in
                    if let err = e.error { Tag("FAILED", color: .systemRed).help(err) } else { Tag("SUCCESS", color: .systemGreen) }
                }
                .width(74)
                TableColumn("Rows") { e in
                    Text(e.rowCount.map { Fmt.count(Int64($0)) } ?? "—").font(DS.Typo.callout).monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 50, ideal: 64, max: 90)
                TableColumn("Duration") { e in
                    HStack(spacing: DS.Space.s) {
                        GeometryReader { g in
                            Capsule().fill(Color.primary.opacity(0.06))
                                .overlay(alignment: .leading) {
                                    Capsule().fill(e.error == nil ? Color.accentColor.opacity(0.7) : Color.red.opacity(0.7))
                                        .frame(width: max(3, g.size.width * min(1, e.duration / maxDuration)))
                                }
                        }
                        .frame(height: 5)
                        Text(Fmt.duration(e.duration)).font(DS.Typo.caption).monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 54, alignment: .trailing)
                    }
                }
                .width(min: 110, ideal: 150)
                TableColumn("Source") { e in Tag(e.source.uppercased(), color: .systemGray, style: .outline) }
                    .width(min: 60, ideal: 76, max: 100)
            }
            .contextMenu(forSelectionType: Int64.self) { ids in
                if let id = ids.first, let e = entries.first(where: { $0.id == id }) { menu(e) }
            } primaryAction: { ids in
                if let id = ids.first, let e = entries.first(where: { $0.id == id }) { model.openQueryTab(title: "History", sql: e.sql, run: false) }
            }
            StatusBar {
                Text("\(shown.count) statement\(shown.count == 1 ? "" : "s")").monospacedDigit()
                let failed = entries.filter { $0.error != nil }.count
                if failed > 0 { Text("\(failed) failed").foregroundStyle(.red) }
            } trailing: {
                Text("Double-click to open in a query tab").foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func menu(_ e: HistoryEntry) -> some View {
        Button("Open in New Query Tab") { model.openQueryTab(title: "History", sql: e.sql, run: false) }
        Button("Run in New Query Tab") { model.openQueryTab(title: "History", sql: e.sql, run: true) }
        Button("Copy") { Pasteboard.copy(e.sql) }
        Divider()
        Button("Delete") { HistoryStore.shared.delete(e.id); reload() }
    }

    private func reload() {
        let q = compact ? model.sidebarFilter : search
        let id = allConnections ? nil : model.connection.id
        DispatchQueue.global(qos: .userInitiated).async {
            let rows = HistoryStore.shared.entries(connectionID: id, search: q, limit: 400)
            DispatchQueue.main.async { entries = rows }
        }
    }
}

/// Sidebar "Queries": saved favorites, then the most recent distinct statements of this connection.
struct FavoritesListView: View {
    var model: WorkspaceModel
    var compact = false
    @State private var items: [SavedQuery] = []
    @State private var recent: [HistoryEntry] = []

    var body: some View {
        List {
            Section {
                if filtered.isEmpty {
                    Text(items.isEmpty ? "Save a query with ⌥⌘S to keep it here." : "No match")
                        .font(DS.Typo.caption).foregroundStyle(.secondary)
                }
                ForEach(filtered) { q in
                    HStack(alignment: .top, spacing: DS.Space.s) {
                        Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(.yellow).padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: DS.Space.xs) {
                                Text(q.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                if !q.keyword.isEmpty { Tag(q.keyword, color: .systemGray, style: .outline) }
                                Spacer(minLength: 0)
                                if q.connectionID == nil { Image(systemName: "globe").font(.caption2).foregroundStyle(.tertiary).help("All connections") }
                            }
                            Text(q.sql.replacingOccurrences(of: "\n", with: " ")).font(DS.Typo.monoSmall).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { model.openQueryTab(title: q.name, sql: q.sql, run: false) }
                    .contextMenu {
                        Button("Open") { model.openQueryTab(title: q.name, sql: q.sql, run: false) }
                        Button("Run") { model.openQueryTab(title: q.name, sql: q.sql, run: true) }
                        Button("Copy SQL") { Pasteboard.copy(q.sql) }
                        Divider()
                        Button("Delete") { FavoritesStore.shared.delete(q.id); reload() }
                    }
                }
            } header: {
                Text("Favorites")
            }
            if !recentFiltered.isEmpty {
                Section {
                    ForEach(recentFiltered) { e in
                        HStack(spacing: DS.Space.s) {
                            Image(systemName: "clock").font(.system(size: 10)).foregroundStyle(.tertiary)
                            Text(e.sql.replacingOccurrences(of: "\n", with: " ")).font(DS.Typo.monoSmall).lineLimit(1)
                            Spacer(minLength: 0)
                            Text(Fmt.relative(e.executedAt)).font(DS.Typo.micro).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { model.openQueryTab(title: "Recent", sql: e.sql, run: false) }
                        .contextMenu {
                            Button("Open in New Query Tab") { model.openQueryTab(title: "Recent", sql: e.sql, run: false) }
                            Button("Copy") { Pasteboard.copy(e.sql) }
                        }
                        .help(e.sql)
                    }
                } header: {
                    Text("Recent")
                }
            }
        }
        .listStyle(.sidebar)
        .onAppear { reload() }
        .onChange(of: model.console.count) { _, _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .mtpFavoritesDidChange)) { _ in reload() }
    }

    private var filtered: [SavedQuery] {
        let q = model.sidebarFilter.lowercased()
        return q.isEmpty ? items : items.filter { $0.name.lowercased().contains(q) || $0.sql.lowercased().contains(q) || $0.keyword.lowercased().contains(q) }
    }

    private var recentFiltered: [HistoryEntry] {
        let q = model.sidebarFilter.lowercased()
        return q.isEmpty ? recent : recent.filter { $0.sql.lowercased().contains(q) }
    }

    private func reload() {
        items = FavoritesStore.shared.all(for: model.connection.id).sorted { $0.name < $1.name }
        let id = model.connection.id
        DispatchQueue.global(qos: .userInitiated).async {
            var seen = Set<String>()
            let rows = HistoryStore.shared.entries(connectionID: id, search: "", limit: 80)
                .filter { $0.error == nil && $0.source == "editor" }
                .filter { seen.insert($0.sql.trimmingCharacters(in: .whitespacesAndNewlines)).inserted }
            DispatchQueue.main.async { recent = Array(rows.prefix(10)) }
        }
    }
}
