import AppKit
import FeatureAI
import FeatureDataTransfer
import FeatureInsights
import FeatureSchemaTools
import MTPCore
import MTPUIKit
import SwiftUI

struct WorkspaceView: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        NavigationSplitView(columnVisibility: Binding(
            get: { model.showLeftSidebar ? .all : .detailOnly },
            set: { model.showLeftSidebar = $0 != .detailOnly })
        ) {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: DS.Metrics.sidebarWidth, max: 380)
        } detail: {
            VStack(spacing: 0) {
                if model.connection.isProductionLike {
                    // A thin rule under the toolbar; the context bar itself carries the environment.
                    Rectangle().fill(Color(nsColor: NSColor(hex: model.connection.environment.defaultColorHex) ?? .systemRed)).frame(height: 2)
                }
                content
                if model.showConsole {
                    Divider()
                    ConsoleView(model: model).frame(height: 160)
                }
            }
            .inspector(isPresented: $model.showRightSidebar) {
                rightSidebar.inspectorColumnWidth(min: 260, ideal: 320, max: 520)
            }
        }
        .toolbar { WorkspaceToolbar(model: model) }
        .overlay(alignment: .top) {
            if let overlay = model.overlay {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.08).ignoresSafeArea().onTapGesture { model.overlay = nil }
                    OpenAnythingView(model: model, mode: overlay).padding(.top, 60)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Label(toast, systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(DS.Palette.separator, lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                    .padding(.bottom, 40)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.toast)
        .sheet(item: $model.sheet) { sheet in
            sheetView(sheet)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.status {
        case .connecting:
            VStack(spacing: DS.Space.l) {
                ProgressView().controlSize(.small)
                Text("Connecting to \(model.connection.name)…").font(DS.Typo.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            EmptyState("Could not connect to \(model.connection.name)", systemImage: "bolt.horizontal.circle", message: message) {
                Button("Edit Connection…") { model.sheet = .editConnection }
                Button("Retry") { Task { await model.connect() } }.keyboardShortcut(.defaultAction)
            }
        case .disconnected:
            EmptyState("Disconnected", systemImage: "powerplug") {
                Button("Reconnect") { Task { await model.reconnect() } }.keyboardShortcut(.defaultAction)
            }
        case .connected:
            VStack(spacing: 0) {
                TabBarView(model: model)
                tabContent
            }
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        if let tab = model.selectedTab {
            Group {
                if let t = tab as? TableTabModel {
                    TableTabView(tab: t, workspace: model)
                } else if let q = tab as? QueryTabModel {
                    QueryTabView(tab: q, workspace: model)
                } else if let f = tab as? FeatureTabModel {
                    FeatureTabView(tab: f, model: model)
                }
            }
            .id(tab.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            EmptyWorkspaceView(model: model)
        }
    }

    /// Claude for every tab; table tabs can switch to the selected row's fields.
    @ViewBuilder
    private var rightSidebar: some View {
        VStack(spacing: 0) {
            if model.selectedTab is TableTabModel {
                HStack {
                    CompactSegmented([(label: "Claude", value: WorkspaceModel.InspectorMode.claude),
                                      (label: "Row", value: WorkspaceModel.InspectorMode.row)], selection: $model.inspectorMode)
                    Spacer()
                }
                .padding(.horizontal, DS.Space.l)
                .frame(height: 34)
                .background(DS.Palette.bar)
                .overlay(alignment: .bottom) { Divider() }
            }
            if model.inspectorMode == .row, let t = model.selectedTab as? TableTabModel {
                RowDetailView(tab: t)
            } else {
                AIAssistantView(model: model.assistant)
            }
        }
    }

    @ViewBuilder
    private func sheetView(_ sheet: WorkspaceSheet) -> some View {
        let close = { model.sheet = nil }
        switch sheet {
        case .export(let source):
            ExportView(context: model, source: source, onClose: close).frame(minWidth: 560, minHeight: 440)
        case .importCSV(let schema, let table):
            ImportCSVView(context: model, schema: schema, table: table, onClose: { close(); model.refreshSidebar() })
                .frame(minWidth: 760, minHeight: 560)
        case .backup:
            BackupView(connection: model.connection, database: model.currentDatabase, onClose: close).frame(minWidth: 620, minHeight: 520)
        case .restore:
            RestoreView(connection: model.connection, database: model.currentDatabase, onClose: { close(); model.refreshSidebar() })
                .frame(minWidth: 620, minHeight: 520)
        case .editConnection:
            ConnectionFormView(draft: .edit(model.connection), onClose: {
                close()
                if let updated = ConnectionStore.shared.connection(model.connection.id) { model.updateConnection(updated) }
            })
        case .preview(let title, let sql):
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.headline)
                CodeView(sql).frame(minHeight: 240).overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.3)))
                HStack {
                    Button("Copy") { Pasteboard.copy(sql) }
                    Button("Open in Query Tab") { close(); model.openQueryTab(title: "Changes", sql: sql, run: false) }
                    Spacer()
                    Button("Close") { close() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .frame(minWidth: 620, minHeight: 360)
        }
    }
}

/// Window toolbar: navigation on the left, the context bar in the center, grouped actions on the right.
struct WorkspaceToolbar: ToolbarContent {
    @Bindable var model: WorkspaceModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            ControlGroup {
                Button { model.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                    .help("Back (⌃⌘←)")
                Button { model.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                    .help("Forward (⌃⌘→)")
            }
            .controlGroupStyle(.navigation)
        }
        ToolbarItem(placement: .principal) {
            ContextBar(model: model)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            ControlGroup {
                Button { model.overlay = .openAnything } label: { Label("Open Anything", systemImage: "magnifyingglass") }
                    .help("Open Anything (⌘P)")
                Button { model.openQueryTab(title: nil, sql: "", run: false) } label: { Label("New Query", systemImage: "square.and.pencil") }
                    .help("New query tab (⌘T)")
            }
            Menu {
                if model.connection.driver == .postgres {
                    Button { model.openFeature(.insights) } label: { Label("Database Insights", systemImage: "gauge.with.dots.needle.67percent") }
                    Button { model.openFeature(.processList) } label: { Label("Process List", systemImage: "list.bullet.rectangle") }
                    if model.connection.effectiveAWS != nil {
                        Button { model.openFeature(.rds) } label: { Label("AWS RDS Monitoring", systemImage: "cloud") }
                    }
                    Divider()
                }
                Button { model.openFeature(.diagram(schema: model.currentSchema)) } label: { Label("ER Diagram", systemImage: "point.3.connected.trianglepath.dotted") }
                Button { model.openFeature(.schemaDiff) } label: { Label("Schema Diff", systemImage: "arrow.left.arrow.right.square") }
                Button { model.openFeature(.typeScript(schema: model.currentSchema, tables: nil)) } label: { Label("Kysely Types", systemImage: "curlybraces.square") }
                Button { model.openFeature(.databaseSearch) } label: { Label("Search in Database", systemImage: "text.magnifyingglass") }
                Button { model.openFeature(.history) } label: { Label("Query History", systemImage: "clock.arrow.circlepath") }
                Divider()
                Button { model.sheet = .export(.tables(schema: model.currentSchema, names: model.objects.filter { $0.kind == .table }.map(\.name))) } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                Button { model.sheet = .importCSV(schema: model.currentSchema, table: nil) } label: { Label("Import CSV…", systemImage: "square.and.arrow.down") }
                Button { model.sheet = .backup } label: { Label("Backup…", systemImage: "externaldrive") }
                Button { model.sheet = .restore } label: { Label("Restore…", systemImage: "arrow.counterclockwise") }
            } label: {
                Label("Tools", systemImage: "wrench.and.screwdriver")
            }
            .help("Tools")
            Button { model.toggleClaude() } label: { Label("Claude", systemImage: "sparkles") }
                .help("Ask Claude about this database (⌘L)")
            ControlGroup {
                Toggle(isOn: $model.showConsole) { Label("Console", systemImage: "terminal") }
                    .help("Console log (⌃⌘C)")
                Toggle(isOn: Binding(get: { model.showRightSidebar }, set: { on in
                    if on, model.selectedTab is TableTabModel { model.inspectorMode = .row }
                    model.showRightSidebar = on
                })) { Label("Inspector", systemImage: "sidebar.right") }
                    .help("Toggle inspector (⌥⌘0)")
            }
        }
    }
}

/// The "address bar" of the window (TablePlus-style, with Plane/Supabase switchers): environment, connection,
/// database, schema and the object in the current tab, each segment opening its switcher; server, TLS and
/// safety on the right. Staging/production tint the whole bar so the environment is unmistakable.
struct ContextBar: View {
    @Bindable var model: WorkspaceModel

    private var c: ConnectionConfig { model.connection }
    private var envColor: NSColor { NSColor(hex: c.environment.defaultColorHex) ?? .systemGray }

    /// Width left for the bar once the window controls, navigation and action groups are placed.
    /// Computed from the window width because the toolbar bridge sizes items by their full-size variant.
    private var width: CGFloat {
        // The principal item is centered on the whole window, so the larger side (sidebar + navigation) bounds it.
        // The inspector column takes its width out of the toolbar too.
        let reserved: CGFloat = (model.showLeftSidebar ? 740 : 500) + (model.showRightSidebar ? 340 : 0)
        return max(180, min(820, model.windowWidth - reserved))
    }

    var body: some View {
        // Drops detail as space shrinks: server version first, then the open object, then the database.
        let w = width
        bar(showServer: w >= 620, showObject: w >= 450, showDatabase: w >= 340, showSchema: w >= 300)
            .frame(width: w)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(border, lineWidth: c.isProductionLike ? 1 : 0.5))
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
    }

    private func bar(showServer: Bool, showObject: Bool, showDatabase: Bool, showSchema: Bool) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: DS.Space.xs) {
                statusDot.padding(.trailing, 2)
                if c.environment != .local { EnvironmentTag(environment: c.environment, compact: true) }
                connectionMenu
                    .frame(width: min(nameWidth, max(60, width - (showSchema ? 230 : 140))), alignment: .leading)
                if c.driver == .postgres, showDatabase {
                    chevron
                    databaseMenu
                }
                if showSchema {
                    chevron
                    schemaMenu
                }
                if showObject, let object = currentObject {
                    chevron
                    objectLabel(object)
                }
            }
            Spacer(minLength: DS.Space.m)
            trailingInfo(showServer: showServer, compactSafety: !showObject).layoutPriority(-1)
        }
        .font(.system(size: 12))
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 28)
    }

    private var fill: Color {
        c.isProductionLike ? Color(nsColor: envColor).opacity(0.10) : Color.primary.opacity(0.05)
    }

    private var border: Color {
        c.isProductionLike ? Color(nsColor: envColor).opacity(0.55) : DS.Palette.separator.opacity(0.8)
    }

    /// Natural width of the connection segment (semibold 12pt text + label padding); menus would otherwise take all offered space.
    private var nameWidth: CGFloat {
        (c.name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width.rounded(.up) + 12
    }

    private var chevron: some View {
        Image(systemName: "chevron.compact.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
    }

    @ViewBuilder
    private var statusDot: some View {
        switch model.status {
        case .connecting: ProgressView().controlSize(.mini).frame(width: 8)
        case .connected: Circle().fill(Color.green).frame(width: 7, height: 7).help("Connected")
        case .failed(let m): Circle().fill(Color.red).frame(width: 7, height: 7).help(m)
        case .disconnected: Circle().fill(Color.gray).frame(width: 7, height: 7).help("Disconnected")
        }
    }

    private func segment(_ title: String, _ icon: String?, bold: Bool = false) -> some View {
        SegmentLabel(title: title, icon: icon, bold: bold)
    }

    private var connectionMenu: some View {
        Menu {
            Button("Reconnect") { Task { await model.reconnect() } }
            Button("Edit Connection…") { model.sheet = .editConnection }
            Divider()
            Menu("Open Another Connection") {
                ForEach(ConnectionStore.shared.connections.filter { $0.id != c.id }) { other in
                    Button(other.name) { AppDelegate.shared.openWorkspace(other) }
                }
            }
            Button("Copy Connection URL") { Pasteboard.copy(ConnectionURL.make(c, password: nil)) }
        } label: {
            segment(c.name, nil, bold: true)
        }
        .fixedSize(horizontal: false, vertical: true)
        .help("Connection: \(c.subtitle)")
    }

    private var databaseMenu: some View {
        Menu {
            ForEach(model.databases, id: \.self) { db in
                Button { Task { await model.switchDatabase(db) } } label: {
                    if db == model.currentDatabase { Label(db, systemImage: "checkmark") } else { Text(db) }
                }
            }
            if model.databases.count > 12 {
                Divider()
                Button("Search Databases…") { model.overlay = .databaseSwitcher }
            }
        } label: {
            segment(model.currentDatabase, "cylinder.split.1x2")
        }
        .fixedSize()
        .help("Switch database (⌘K)")
    }

    private var schemaMenu: some View {
        Menu {
            ForEach(model.schemas, id: \.self) { schema in
                Button { Task { await model.switchSchema(schema) } } label: {
                    if schema == model.currentSchema { Label(schema, systemImage: "checkmark") } else { Text(schema) }
                }
            }
            if model.schemas.count > 12 {
                Divider()
                Button("Search Schemas…") { model.overlay = .schemaSwitcher }
            }
        } label: {
            segment(model.currentSchema, "square.stack.3d.up")
        }
        .fixedSize()
        .help("Switch schema (⌥⌘K)")
    }

    /// What the selected tab shows: a table/view, a query or a tool.
    private var currentObject: (title: String, icon: String, object: DBObject?)? {
        guard let tab = model.selectedTab else { return nil }
        if let t = tab as? TableTabModel { return (t.object.name, t.object.kind.symbolName, t.object) }
        return (tab.title, tab.icon, nil)
    }

    private func objectLabel(_ o: (title: String, icon: String, object: DBObject?)) -> some View {
        Menu {
            if let obj = o.object {
                Button("Copy Name") { Pasteboard.copy(obj.name) }
                Button("Copy Qualified Name") { Pasteboard.copy(model.dialect.qualified(schema: obj.schema, name: obj.name)) }
                Button(model.isPinned(obj) ? "Unpin from Sidebar" : "Pin in Sidebar") { model.togglePin(obj) }
            } else {
                Button("Copy Title") { Pasteboard.copy(o.title) }
            }
        } label: {
            segment(o.title, o.icon)
        }
        .fixedSize()
    }

    private func trailingInfo(showServer: Bool, compactSafety: Bool) -> some View {
        HStack(spacing: DS.Space.s) {
            if showServer, let info = model.serverInfo {
                Text("\(info.product) \(info.version)").font(DS.Typo.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help(info.currentUser.isEmpty ? "\(info.product) \(info.version)" : "\(info.product) \(info.version) · signed in as \(info.currentUser)")
            }
            if c.driver == .postgres { tlsBadge }
            safetyMenu(compact: compactSafety).fixedSize()
        }
    }

    @ViewBuilder
    private var tlsBadge: some View {
        let local = ["localhost", "127.0.0.1", "::1"].contains(c.host.lowercased())
        switch c.sslMode {
        case .require, .verifyCA, .verifyFull:
            Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(.secondary).help("TLS required (sslmode=\(c.sslMode.rawValue))")
        case .prefer, .allow:
            if !local { Image(systemName: "lock").font(.system(size: 10)).foregroundStyle(.tertiary).help("TLS if the server offers it (sslmode=\(c.sslMode.rawValue))") }
        case .disable:
            if !local { Image(systemName: "lock.open").font(.system(size: 10)).foregroundStyle(.orange).help("TLS disabled (sslmode=disable)") }
        }
    }

    /// Safety level as a compact chip; picking another level goes through the window (Touch ID when lowering on production).
    private func safetyMenu(compact: Bool) -> some View {
        Menu {
            ForEach(SafetyLevel.allCases) { level in
                Button {
                    let item = NSMenuItem()
                    item.tag = level.rawValue
                    (model.window as? WorkspaceWindow)?.setSafetyLevel(item)
                } label: {
                    if level == c.safety { Label(level.displayName, systemImage: "checkmark") } else { Text(level.displayName) }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: safetyIcon).font(.system(size: 10, weight: .semibold))
                if !compact { Text(safetyShort).font(.system(size: 10, weight: .semibold)) }
            }
            .foregroundStyle(safetyColor)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(safetyColor.opacity(0.12)))
        }
        .fixedSize()
        .help("Safety: \(c.safety.displayName)")
    }

    private var safetyIcon: String {
        switch c.safety {
        case .silent: return "bolt"
        case .confirmWrites: return "exclamationmark.shield"
        case .protectedWrites: return "touchid"
        case .readOnly: return "lock.fill"
        }
    }

    private var safetyShort: String {
        switch c.safety {
        case .silent: return "WRITES"
        case .confirmWrites: return "CONFIRM"
        case .protectedWrites: return "TOUCH ID"
        case .readOnly: return "READ-ONLY"
        }
    }

    private var safetyColor: Color {
        switch c.safety {
        case .silent: return .secondary
        case .confirmWrites: return .orange
        case .protectedWrites: return .red
        case .readOnly: return .blue
        }
    }
}

/// One clickable segment of the context bar, with a hover highlight like a breadcrumb button.
private struct SegmentLabel: View {
    var title: String
    var icon: String?
    var bold: Bool
    @State private var hover = false

    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary) }
            Text(title).font(.system(size: 12, weight: bold ? .semibold : .regular)).lineLimit(1).truncationMode(.tail)
        }
        .padding(.horizontal, 5)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(hover ? Color.primary.opacity(0.08) : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

struct TabBarView: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(model.tabs, id: \.id) { tab in
                            TabButton(tab: tab, selected: tab.id == model.selectedTabID,
                                      select: { model.select(tab.id) }, close: { model.closeTab(tab.id) },
                                      pin: { tab.isPreview = false })
                            .id(tab.id)
                        }
                    }
                }
                .onChange(of: model.selectedTabID) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id) } }
                }
            }
            Button { model.openQueryTab(title: nil, sql: "", run: false) } label: {
                Image(systemName: "plus").font(.system(size: 11, weight: .medium)).frame(width: 28, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, DS.Space.xs)
            .help("New query tab (⌘T)")
        }
        .frame(height: DS.Metrics.tabBarHeight)
        .background(DS.Palette.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct TabButton: View {
    var tab: WorkspaceTab
    var selected: Bool
    var select: () -> Void
    var close: () -> Void
    var pin: () -> Void
    @State private var hover = false
    @State private var closeHover = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: tab.icon)
                .font(.system(size: 10.5))
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .frame(width: 14)
            Text(tab.title)
                .font(.system(size: 12, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .italic(tab.isPreview)
                .lineLimit(1)
            Spacer(minLength: 0)
            ZStack {
                if tab.hasUnsavedChanges && !hover {
                    Circle().fill(Color.orange).frame(width: 6, height: 6)
                } else {
                    Button(action: close) {
                        Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold))
                            .frame(width: 16, height: 16)
                            .background(Circle().fill(closeHover ? DS.Palette.pressed : .clear))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .onHover { closeHover = $0 }
                    .opacity(hover || selected ? 1 : 0)
                }
            }
            .frame(width: 16)
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: DS.Metrics.tabBarHeight)
        .frame(minWidth: 110, maxWidth: 210)
        .background(selected ? Color(nsColor: .textBackgroundColor) : (hover ? DS.Palette.hover : .clear))
        .overlay(alignment: .top) {
            if selected { Rectangle().fill(Color.accentColor).frame(height: 2) }
        }
        .overlay(alignment: .trailing) {
            Rectangle().fill(DS.Palette.separator.opacity(0.6)).frame(width: 0.5).padding(.vertical, selected ? 0 : 8)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { pin() }
        .onTapGesture { select() }
        .onHover { hover = $0 }
        .help(tab.isPreview ? "Preview tab — double-click to keep it open" : tab.title)
    }
}

struct EmptyWorkspaceView: View {
    var model: WorkspaceModel

    var body: some View {
        VStack(spacing: DS.Space.xxl) {
            EmptyState("Nothing open", systemImage: "tablecells", message: "Pick a table in the sidebar, or start from one of these.")
                .frame(maxHeight: 180)
            VStack(spacing: 2) {
                shortcut("New Query", "square.and.pencil", "⌘T") { model.openQueryTab(title: nil, sql: "", run: false) }
                shortcut("Open Anything", "magnifyingglass", "⌘P") { model.overlay = .openAnything }
                shortcut("Command Palette", "command", "⇧⌘P") { model.overlay = .commandPalette }
                if model.connection.driver == .postgres {
                    shortcut("Database Insights", "gauge.with.dots.needle.67percent", "⌥⌘I") { model.openFeature(.insights) }
                }
                shortcut("ER Diagram", "point.3.connected.trianglepath.dotted", "⌥⌘D") { model.openFeature(.diagram(schema: model.currentSchema)) }
            }
            .frame(width: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func shortcut(_ title: String, _ icon: String, _ keys: String, action: @escaping () -> Void) -> some View {
        HoverRow(action: action) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18)
            Text(title).font(DS.Typo.body)
            Spacer()
            KeyCap(keys)
        }
    }
}

/// Full-width clickable row with a hover highlight.
struct HoverRow<Content: View>: View {
    var action: () -> Void
    @ViewBuilder var content: Content
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.m) { content }
                .padding(.horizontal, DS.Space.m)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).fill(hover ? DS.Palette.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct ConsoleView: View {
    var model: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                SectionLabel("Console", count: model.console.count)
                Button("Clear") { model.console.removeAll() }.buttonStyle(.borderless).font(DS.Typo.caption)
            }
            .padding(.horizontal, DS.Space.l)
            .frame(height: 28)
            .background(DS.Palette.bar)
            Divider()
            ScrollViewReader { proxy in
                List(model.console) { e in
                    HStack(alignment: .top, spacing: 8) {
                        Text(e.date, style: .time).foregroundStyle(.tertiary)
                        Text(e.sql.replacingOccurrences(of: "\n", with: " ")).lineLimit(2).textSelection(.enabled)
                        Spacer()
                        Text(e.isError ? e.outcome : "\(e.outcome)").foregroundStyle(e.isError ? .red : .secondary).lineLimit(1)
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .id(e.id)
                }
                .listStyle(.plain)
                .onChange(of: model.console.count) { _, _ in if let last = model.console.last { proxy.scrollTo(last.id) } }
            }
        }
    }
}

struct FeatureTabView: View {
    var tab: FeatureTabModel
    var model: WorkspaceModel

    var body: some View {
        switch tab.kind {
        case .insights: InsightsDashboardView(context: model)
        case .processList: ProcessListView(context: model)
        case .diagram(let schema): ERDiagramView(context: model, schema: schema)
        case .schemaDiff: SchemaDiffView(context: model)
        case .typeScript(let schema, let tables): TypeScriptExportView(context: model, schema: schema, tables: tables)
        case .explain(let sql): ExplainPlanView(context: model, sql: sql)
        case .history: HistoryListView(model: model)
        case .favorites: FavoritesListView(model: model)
        case .databaseSearch: DatabaseSearchView(model: model)
        case .rds: RDSDashboardView(context: model)
        }
    }
}
