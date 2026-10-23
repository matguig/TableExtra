import AppKit
import MTPCore
import MTPUIKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class TypeScriptExportModel: ObservableObject {
    let context: WorkspaceContext
    let initialSchema: String
    let initialTables: [String]?

    @Published private(set) var includedSchemas: [String]
    @Published private(set) var snapshots: [String: SchemaSnapshot] = [:]
    /// TableDetails.object.id of the tables to export.
    @Published var selected: Set<String> = []
    @Published var options = TypeScriptOptions()
    @Published var filter = ""
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    init(context: WorkspaceContext, schema: String, tables: [String]?) {
        self.context = context
        self.initialSchema = schema
        self.initialTables = tables
        self.includedSchemas = [schema]
        if context.connection.driver == .sqlite { options.defaultSchema = schema }
    }

    var availableSchemas: [String] {
        var s = context.schemas
        if !s.contains(initialSchema) { s.insert(initialSchema, at: 0) }
        return s
    }

    func load() async {
        for s in includedSchemas where snapshots[s] == nil { await loadSchema(s) }
    }

    func toggleSchema(_ schema: String) async {
        if let i = includedSchemas.firstIndex(of: schema) {
            guard includedSchemas.count > 1 else { return }
            includedSchemas.remove(at: i)
            let ids = Set((snapshots[schema]?.tables ?? []).map(\.object.id))
            selected.subtract(ids)
        } else {
            includedSchemas.append(schema)
            includedSchemas.sort { availableSchemas.firstIndex(of: $0) ?? 0 < availableSchemas.firstIndex(of: $1) ?? 0 }
            if snapshots[schema] == nil {
                await loadSchema(schema)
            } else {
                selected.formUnion((snapshots[schema]?.tables ?? []).map(\.object.id))
            }
        }
    }

    private func loadSchema(_ schema: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let snap = try await SchemaSnapshotLoader.load(client: context.client, introspector: context.introspector, schema: schema,
                                                           includeViewDefinitions: false)
            snapshots[schema] = snap
            let wanted: [TableDetails]
            if schema == initialSchema, let names = initialTables, !names.isEmpty {
                let set = Set(names)
                wanted = snap.tables.filter { set.contains($0.object.name) }
            } else {
                wanted = snap.tables
            }
            selected.formUnion(wanted.map(\.object.id))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Tables of the included schemas, filtered by kind (views option) and the search field.
    var listedTables: [TableDetails] {
        let kinds: Set<DBObjectKind> = options.includeViews ? [.table, .foreignTable, .view, .materializedView] : [.table, .foreignTable]
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return includedSchemas.flatMap { snapshots[$0]?.tables ?? [] }
            .filter { kinds.contains($0.object.kind) && (q.isEmpty || $0.object.name.lowercased().contains(q)) }
    }

    var exportedTables: [TableDetails] {
        let kinds: Set<DBObjectKind> = options.includeViews ? [.table, .foreignTable, .view, .materializedView] : [.table, .foreignTable]
        return includedSchemas.flatMap { snapshots[$0]?.tables ?? [] }.filter { kinds.contains($0.object.kind) && selected.contains($0.object.id) }
    }

    var enumMap: [String: [String]] {
        var out: [String: [String]] = [:]
        for s in includedSchemas {
            for e in snapshots[s]?.enums ?? [] {
                if s == options.defaultSchema { out[e.name] = e.values } else { out["\(s).\(e.name)"] = e.values }
            }
        }
        return out
    }

    var effectiveOptions: TypeScriptOptions {
        var o = options
        for s in includedSchemas { o.domains.merge(snapshots[s]?.domains ?? [:]) { a, _ in a } }
        return o
    }

    var output: String {
        TypeScriptGenerator.generate(tables: exportedTables, enums: enumMap, options: effectiveOptions)
    }

    func setAll(_ on: Bool) {
        let ids = listedTables.map(\.object.id)
        if on { selected.formUnion(ids) } else { selected.subtract(ids) }
    }

    func toggle(_ t: TableDetails) {
        if selected.contains(t.object.id) { selected.remove(t.object.id) } else { selected.insert(t.object.id) }
    }

    func copy() {
        Pasteboard.copy(output)
        context.showToast("TypeScript copied")
    }

    func save() {
        let type = UTType(filenameExtension: "ts", conformingTo: .sourceCode) ?? .plainText
        let name = includedSchemas == ["public"] || includedSchemas.count > 1 ? "db.ts" : "\(includedSchemas[0]).ts"
        FilePanels.save(output, suggestedName: name, types: [type])
    }
}

struct TypeScriptExportScreen: View {
    @StateObject private var model: TypeScriptExportModel

    init(context: WorkspaceContext, schema: String, tables: [String]?) {
        _model = StateObject(wrappedValue: TypeScriptExportModel(context: context, schema: schema, tables: tables))
    }

    var body: some View {
        TypeScriptExportContent(model: model)
            .task { await model.load() }
    }
}

struct TypeScriptExportContent: View {
    @ObservedObject var model: TypeScriptExportModel
    @State private var listFraction: CGFloat = 0.26

    var body: some View {
        SplitPane(axis: .horizontal, fraction: $listFraction, minFirst: 210, minSecond: 420) {
            TableChecklist(model: model)
        } second: {
            VStack(spacing: 0) {
                TypeScriptOptionsBar(model: model)
                if let e = model.errorMessage {
                    Banner(.error, e).frame(minWidth: 300).padding(DS.Space.m)
                }
                ZStack {
                    CodeView(model.output, language: .typescript)
                    if model.isLoading && model.snapshots.isEmpty { ProgressView().controlSize(.small) }
                }
                StatusBar {
                    let out = model.output
                    let lines = out.split(separator: "\n", omittingEmptySubsequences: false).count
                    Text("\(model.exportedTables.count) \(model.exportedTables.count == 1 ? "table" : "tables") · \(lines) lines").monospacedDigit()
                } trailing: {
                    Text(model.options.style == .kysely ? "kysely-codegen compatible" : "Plain TypeScript").foregroundStyle(.tertiary)
                }
            }
        }
        .background {
            HiddenShortcut(key: "c", modifiers: [.command, .shift]) { model.copy() }
            HiddenShortcut(key: "s") { model.save() }
        }
    }
}

struct TypeScriptOptionsBar: View {
    @ObservedObject var model: TypeScriptExportModel

    var body: some View {
        ToolStrip {
            CompactSegmented(TypeScriptOptions.Style.allCases.map { (label: $0 == .kysely ? "Kysely" : "Interfaces", value: $0) },
                             selection: $model.options.style)
                .help("Kysely: kysely-codegen compatible types. Interfaces: plain row interfaces.")
            ToolDivider()
            TypeScriptOptionsMenu(options: $model.options)
            ActiveOptionTags(options: model.options)
        } trailing: {
            ToolButton("Copy", systemImage: "doc.on.doc", shortcut: "⇧⌘C") { model.copy() }
            ToolButton("Save…", systemImage: "square.and.arrow.down", shortcut: "⌘S") { model.save() }
        }
    }
}

/// "Options ▾" menu holding the generator switches, so they never wrap in the toolbar.
struct TypeScriptOptionsMenu: View {
    @Binding var options: TypeScriptOptions
    @Environment(\.toolStripCompact) private var compact

    var body: some View {
        Menu {
            Toggle("camelCase Keys", isOn: $options.camelCase)
            Toggle("Include Views", isOn: $options.includeViews)
            Toggle("Zod Schemas", isOn: $options.zod)
            Toggle("Sort Properties", isOn: $options.sortProperties)
            Toggle("Comments", isOn: $options.includeComments)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 11.5, weight: .medium))
                if !compact { Text("Options").lineLimit(1).fixedSize() }
            }
            .font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, DS.Space.xs)
        .help("camelCase for Kysely's CamelCasePlugin, views, Zod schemas, alphabetical properties (like kysely-codegen), comments")
    }
}

/// Small tags summarizing the non-default options, hidden when the strip is narrow.
struct ActiveOptionTags: View {
    var options: TypeScriptOptions
    @Environment(\.toolStripCompact) private var compact

    var body: some View {
        if !compact {
            HStack(spacing: DS.Space.xs) {
                if options.camelCase { Tag("camelCase", color: .systemBlue) }
                if options.zod { Tag("Zod", color: .systemIndigo) }
                if !options.includeViews { Tag("No views", color: .systemGray) }
            }
        }
    }
}

struct TableChecklist: View {
    @ObservedObject var model: TypeScriptExportModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.s) {
                Menu {
                    ForEach(model.availableSchemas, id: \.self) { s in
                        Button {
                            Task { await model.toggleSchema(s) }
                        } label: {
                            if model.includedSchemas.contains(s) { Label(s, systemImage: "checkmark") } else { Text(s) }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "square.stack.3d.up").font(.system(size: 11))
                        Text(model.includedSchemas.joined(separator: ", ")).lineLimit(1).truncationMode(.tail)
                    }
                    .font(.system(size: 12, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Schemas to export")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Space.l)
            .frame(height: DS.Metrics.toolbarHeight)
            .background(DS.Palette.bar)
            .overlay(alignment: .bottom) { Divider() }

            VStack(spacing: DS.Space.m) {
                ToolSearchField(prompt: "Filter tables", text: $model.filter, width: nil)
                SectionLabel("Tables", count: model.listedTables.count) {
                    HStack(spacing: DS.Space.s) {
                        Button("All") { model.setAll(true) }
                        Text("·").foregroundStyle(.tertiary)
                        Button("None") { model.setAll(false) }
                    }
                    .buttonStyle(.plain)
                    .font(DS.Typo.caption)
                    .foregroundStyle(Color.accentColor)
                    .fixedSize()
                }
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.top, DS.Space.m)
            .padding(.bottom, DS.Space.xs)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.listedTables, id: \.object.id) { t in
                        ChecklistRow(table: t, on: model.selected.contains(t.object.id),
                                     title: t.object.schema == model.options.defaultSchema ? t.object.name : t.object.qualifiedName) {
                            model.toggle(t)
                        }
                    }
                }
                .padding(.horizontal, DS.Space.s)
                .padding(.vertical, DS.Space.xs)
            }
            StatusBar {
                Text("\(model.exportedTables.count) of \(model.listedTables.count) selected").monospacedDigit()
            }
        }
        .background(DS.Palette.bar.opacity(0.5))
    }
}

struct ChecklistRow: View {
    let table: TableDetails
    let on: Bool
    let title: String
    let toggle: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: on ? "checkmark.square.fill" : "square")
                .font(.system(size: 13))
                .foregroundStyle(on ? Color.accentColor : Color.secondary)
            Image(systemName: table.object.kind.symbolName).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 14)
            Text(title).font(DS.Typo.body).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(on ? Color.primary : Color.secondary)
            Spacer(minLength: 0)
            Text("\(table.columns.count)").font(DS.Typo.caption).monospacedDigit().foregroundStyle(.tertiary)
        }
        .padding(.horizontal, DS.Space.s)
        .frame(height: DS.Metrics.rowHeight)
        .background(RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous).fill(hover ? DS.Palette.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: toggle)
        .help("\(table.columns.count) columns")
    }
}
