import AppKit
import MTPCore
import MTPUIKit
import SwiftUI

@MainActor
final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    let model = WelcomeModel()

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 580),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.setFrameAutosaveName("WelcomeWindow")
        window.minSize = NSSize(width: 760, height: 480)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: WelcomeView(model: model))
        window.delegate = self
        if window.frame.origin == .zero { window.center() }
        // Frames saved before the redesign are too small for the filters and recent cards.
        if window.frame.width < 880 || window.frame.height < 560 {
            window.setContentSize(NSSize(width: 920, height: 580))
            window.center()
        }
    }

    required init?(coder: NSCoder) { fatalError() }
}

struct WelcomeView: View {
    @Bindable var model: WelcomeModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            leftPane
                .frame(width: 236)
                .background(.regularMaterial)
            Divider()
            rightPane
        }
        .ignoresSafeArea()
        .sheet(item: $model.editing) { draft in
            ConnectionFormView(draft: draft, onClose: { model.editing = nil })
        }
        .background(
            Button("") { searchFocused = true }.keyboardShortcut("f").hidden()
        )
    }

    private var leftPane: some View {
        VStack(spacing: DS.Space.s) {
            Spacer().frame(height: 44)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
                .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
            Text("TableExtra").font(.system(size: 19, weight: .semibold))
                .padding(.top, DS.Space.s)
            Text("Version \(AppSettings.appVersion)").font(DS.Typo.caption).foregroundStyle(.secondary)
            Spacer()
            VStack(spacing: 2) {
                WelcomeButton(title: "New Connection", icon: "plus", keys: "⇧⌘N") { model.editing = .new() }
                if model.tablePlusAvailable {
                    WelcomeButton(title: "Import from TablePlus", icon: "square.and.arrow.down") {
                        AppDelegate.shared.importFromTablePlus(nil)
                    }
                }
                WelcomeButton(title: "Open SQLite File…", icon: "doc") { model.openSQLiteFile() }
                WelcomeButton(title: "Connect with URL…", icon: "link") { AppDelegate.shared.openConnectionURL(nil) }
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.bottom, DS.Space.xl)
        }
    }

    private var rightPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.m) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.tertiary)
                    TextField("Search connections", text: $model.search)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .onSubmit {
                            if let first = model.sections.first?.items.first { model.connect(first.id) }
                        }
                    if model.search.isEmpty { KeyCap("⌘F") }
                }
                .padding(.horizontal, DS.Space.m)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: DS.Radius.m + 1, style: .continuous).fill(Color.primary.opacity(0.055)))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.m + 1, style: .continuous)
                    .strokeBorder(searchFocused ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1))
                Menu {
                    Picker("Sort By", selection: $model.sort) {
                        ForEach(ConnectionSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Divider()
                    Button("New Connection…") { model.editing = .new() }
                    Button("New Group…") { model.newGroup() }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Sort and organize")
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.top, 36)
            .padding(.bottom, DS.Space.s)
            if !model.connections.isEmpty { environmentChips }
            if model.search.isEmpty && model.environmentFilter == nil && recent.count >= 2 {
                recentStrip
            }
            if model.connections.isEmpty {
                emptyState
            } else {
                List(selection: $model.selection) {
                    ForEach(model.sections) { section in
                        Section {
                            ForEach(section.items) { c in
                                ConnectionRow(config: c, selected: model.selection == c.id,
                                              connect: { model.connect(c.id) }) { rowMenu(c.id) }
                                    .tag(c.id)
                                    .listRowSeparator(.hidden)
                                    .listRowInsets(EdgeInsets(top: 1, leading: DS.Space.s, bottom: 1, trailing: DS.Space.s))
                            }
                        } header: {
                            SectionLabel(section.title, count: section.items.count)
                            .contextMenu {
                                if let g = section.group {
                                    Button("Rename Group…") { model.renameGroup(g) }
                                    Button("Delete Group") { model.deleteGroup(g) }
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .overlay {
                    if model.sections.allSatisfy({ $0.items.isEmpty }) {
                        EmptyState("No matching connection", systemImage: "magnifyingglass",
                                   message: "Nothing matches the search or the selected environment.") {
                            Button("Clear Filters") { model.search = ""; model.environmentFilter = nil }
                        }
                    }
                }
                .contextMenu(forSelectionType: UUID.self) { ids in
                    if let id = ids.first { rowMenu(id) } else {
                        Button("New Connection…") { model.editing = .new() }
                        Button("New Group…") { model.newGroup() }
                    }
                } primaryAction: { ids in
                    if let id = ids.first { model.connect(id) }
                }
            }
            footer
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    /// Environment filter chips with colored dots and counts (All · Production · Staging · …).
    private var environmentChips: some View {
        let present = ConnectionEnvironment.allCases.reversed().filter { env in model.connections.contains { $0.environment == env } }
        return HStack(spacing: DS.Space.xs) {
            chip(title: "All", count: model.connections.count, color: nil, on: model.environmentFilter == nil) { model.environmentFilter = nil }
            ForEach(present, id: \.self) { env in
                chip(title: env.displayName, count: model.connections.filter { $0.environment == env }.count,
                     color: NSColor(hex: env.defaultColorHex), on: model.environmentFilter == env) {
                    model.environmentFilter = model.environmentFilter == env ? nil : env
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.bottom, DS.Space.m)
    }

    private func chip(title: String, count: Int, color: NSColor?, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let color { Circle().fill(Color(nsColor: color)).frame(width: 6, height: 6) }
                Text(title).lineLimit(1)
                Text("\(count)").monospacedDigit().foregroundStyle(on ? Color.accentColor.opacity(0.8) : Color.secondary.opacity(0.7))
            }
            .font(.system(size: 11.5, weight: on ? .semibold : .regular))
            .foregroundStyle(on ? Color.accentColor : Color.primary.opacity(0.8))
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Capsule().fill(on ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.05)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    private var footer: some View {
        let shown = model.sections.reduce(0) { $0 + $1.items.count }
        return StatusBar {
            Text(shown == model.connections.count ? "\(shown) connection\(shown == 1 ? "" : "s")" : "\(shown) of \(model.connections.count) connections")
                .monospacedDigit()
        } trailing: {
            HStack(spacing: DS.Space.l) {
                hint("↩", "Connect")
                hint("⌘E", "Edit")
                hint("⌘F", "Search")
            }
        }
        .background(
            Group {
                Button("") { if let id = model.selection { model.connect(id) } }.keyboardShortcut(.return, modifiers: [])
                Button("") {
                    if let id = model.selection, let c = model.connections.first(where: { $0.id == id }) { model.editing = .edit(c) }
                }
                .keyboardShortcut("e")
            }
            .hidden()
        )
    }

    private func hint(_ keys: String, _ title: String) -> some View {
        HStack(spacing: 4) {
            KeyCap(keys)
            Text(title)
        }
    }

    /// Last connections used, as quick-open cards above the full list.
    private var recent: [ConnectionConfig] {
        Array(model.connections.filter { $0.lastConnectedAt != nil }
            .sorted { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }
            .prefix(3))
    }

    private var recentStrip: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SectionLabel("Recent")
            HStack(spacing: DS.Space.s) {
                ForEach(recent) { c in RecentCard(config: c) { model.connect(c.id) } }
                if recent.count < 3 { Spacer(minLength: 0) }
            }
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.bottom, DS.Space.m)
    }

    @ViewBuilder
    private func rowMenu(_ id: UUID) -> some View {
        Button("Connect") { model.connect(id) }
        Button("Edit…") {
            if let c = model.connections.first(where: { $0.id == id }) { model.editing = .edit(c) }
        }
        Button("Duplicate") { model.duplicate(id) }
        Button("Copy as URL") { model.copyURL(id) }
        Menu("Move to Group") {
            Button("None") { model.move(id, to: nil) }
            ForEach(model.groups) { g in Button(g.name) { model.move(id, to: g.id) } }
        }
        Divider()
        Button("Delete…", role: .destructive) { model.delete(id) }
    }

    private var emptyState: some View {
        EmptyState("No connections yet", systemImage: "cylinder.split.1x2",
                   message: "Create one, open a SQLite file, or bring everything over from TablePlus.") {
            Button("New Connection") { model.editing = .new() }.buttonStyle(.borderedProminent)
            if model.tablePlusAvailable {
                Button("Import from TablePlus") { AppDelegate.shared.importFromTablePlus(nil) }
            }
        }
    }
}

private struct WelcomeButton: View {
    var title: String
    var icon: String
    var keys: String?
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.m) {
                Image(systemName: icon).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).frame(width: 18)
                Text(title).font(DS.Typo.body).lineLimit(1)
                Spacer(minLength: 0)
                if let keys { KeyCap(keys) }
            }
            .padding(.horizontal, DS.Space.m)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).fill(hover ? DS.Palette.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct RecentCard: View {
    var config: ConnectionConfig
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack(spacing: DS.Space.s) {
                    DriverBadge(driver: config.driver, colorHex: config.effectiveColorHex, size: 22)
                    Text(config.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                HStack(spacing: DS.Space.xs) {
                    if config.environment != .local { EnvironmentTag(environment: config.environment, colorHex: config.colorHex, compact: true) }
                    Text(config.lastConnectedAt.map { Fmt.relative($0) } ?? "").font(DS.Typo.micro).foregroundStyle(.tertiary).lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .padding(DS.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.Radius.l - 2, style: .continuous).fill(hover ? DS.Palette.hover : Color.primary.opacity(0.035)))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.l - 2, style: .continuous).strokeBorder(DS.Palette.separator.opacity(0.7), lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Connect to \(config.name)")
    }
}

struct ConnectionRow<Menu: View>: View {
    var config: ConnectionConfig
    var selected = false
    var connect: () -> Void = {}
    @ViewBuilder var menu: () -> Menu
    @State private var hover = false

    var body: some View {
        HStack(spacing: DS.Space.l) {
            DriverBadge(driver: config.driver, colorHex: config.effectiveColorHex, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: DS.Space.s) {
                    Text(config.name.isEmpty ? "Untitled" : config.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if config.environment != .local { EnvironmentTag(environment: config.environment) }
                    SafetyBadge(level: config.safety).font(.caption)
                    if config.ssh.enabled { Image(systemName: "lock.shield").font(.caption).foregroundStyle(.secondary).help("Over SSH") }
                }
                ConnectionMetaLine(config: config)
            }
            Spacer(minLength: DS.Space.m)
            if hover {
                HStack(spacing: DS.Space.xs) {
                    Button(action: connect) {
                        Text("Connect").font(.system(size: 11.5, weight: .semibold))
                            .padding(.horizontal, 9).frame(height: 22)
                            .foregroundStyle(.white)
                            .background(Capsule().fill(Color.accentColor))
                    }
                    .buttonStyle(.plain)
                    SwiftUI.Menu { menu() } label: { Image(systemName: "ellipsis").frame(width: 22, height: 22) }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                }
            } else if let last = config.lastConnectedAt {
                Text(Fmt.relative(last)).font(DS.Typo.micro).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: DS.Radius.m + 1, style: .continuous)
            .fill(hover && !selected ? DS.Palette.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

/// Short, scannable connection metadata: "user · host · region · RDS · database" instead of a raw URL.
struct ConnectionMetaLine: View {
    var config: ConnectionConfig

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                if i > 0 { Text("·").foregroundStyle(.quaternary) }
                if part.isChip {
                    Text(part.text).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 4).frame(height: 15)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.06)))
                } else {
                    Text(part.text).lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .font(DS.Typo.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .help(config.subtitle)
    }

    struct Part { var text: String; var isChip = false }

    var parts: [Part] { Self.parts(for: config) }

    static func parts(for c: ConnectionConfig) -> [Part] {
        if c.driver == .sqlite {
            return [Part(text: (c.filePath as NSString).abbreviatingWithTildeInPath)]
        }
        var out: [Part] = []
        if !c.user.isEmpty { out.append(Part(text: c.user)) }
        let host = c.host.lowercased()
        if host.hasSuffix(".rds.amazonaws.com") {
            let labels = host.split(separator: ".").map(String.init)
            out.append(Part(text: labels.first ?? host))
            if let region = labels.first(where: { $0.range(of: #"^[a-z]{2}-[a-z]+-\d$"#, options: .regularExpression) != nil }) {
                out.append(Part(text: region))
            }
            out.append(Part(text: labels.contains { $0.hasPrefix("cluster-") } ? "AURORA" : "RDS", isChip: true))
        } else if host == "localhost" || host == "127.0.0.1" || host == "::1" {
            out.append(Part(text: "localhost:\(c.effectivePort)"))
        } else {
            out.append(Part(text: c.effectivePort == 5432 ? c.host : "\(c.host):\(c.effectivePort)"))
        }
        if !c.database.isEmpty { out.append(Part(text: c.database)) }
        return out
    }
}
