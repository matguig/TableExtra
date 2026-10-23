import AppKit
import MTPCore
import MTPUIKit
import SwiftUI

/// Owns the model for the public `SchemaDiffView`.
struct SchemaDiffScreen: View {
    @StateObject private var model: SchemaDiffModel

    init(context: WorkspaceContext) {
        _model = StateObject(wrappedValue: SchemaDiffModel(context: context))
    }

    var body: some View { SchemaDiffContent(model: model) }
}

extension DiffChange {
    var nsColor: NSColor {
        switch self {
        case .added: return .systemGreen
        case .removed: return .systemRed
        case .changed: return .systemOrange
        }
    }

    var color: Color { Color(nsColor: nsColor) }

    var title: String {
        switch self {
        case .added: return "Added"
        case .removed: return "Removed"
        case .changed: return "Changed"
        }
    }
}

/// Colored change tag ("ADDED", "REMOVED", "CHANGED"), or just the symbol when `compact`.
struct ChangeBadge: View {
    let change: DiffChange
    var compact = false

    var body: some View {
        Tag(compact ? change.symbol : change.title.uppercased(), color: change.nsColor)
    }
}

struct SchemaDiffContent: View {
    @ObservedObject var model: SchemaDiffModel
    @State private var listFraction: CGFloat = 0.27
    @State private var detailFraction: CGFloat = 0.5

    var body: some View {
        VStack(spacing: 0) {
            SchemaDiffHeader(model: model)
                .background {
                    HiddenShortcut(key: .return) { Task { await model.compare() } }
                        .disabled(!model.canCompare)
                }
            if model.targetConnection.isProductionLike || (model.targetIsCurrent && model.context.connection.isProductionLike) {
                ProductionBanner(connection: model.targetConnection)
            }
            if let error = model.errorMessage {
                Banner(.error, error)
                    .frame(minWidth: 420)
                    .overlay(alignment: .trailing) {
                        Button { model.errorMessage = nil } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .padding(.trailing, DS.Space.l)
                            .help("Dismiss")
                    }
                    .padding(.horizontal, DS.Space.l)
                    .padding(.top, DS.Space.m)
            }
            if let result = model.result {
                if result.isEmpty {
                    IdenticalSchemasView(model: model, result: result)
                } else {
                    SplitPane(axis: .horizontal, fraction: $listFraction, minFirst: 230, minSecond: 420) {
                        DiffChangeList(model: model, result: result)
                    } second: {
                        SplitPane(axis: .vertical, fraction: $detailFraction, minFirst: 160, minSecond: 160) {
                            DiffDetailPane(model: model)
                        } second: {
                            MigrationPane(model: model)
                        }
                    }
                }
            } else if model.isComparing {
                ProgressView("Comparing…").controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyState("Compare two schemas", systemImage: "arrow.left.arrow.right.square",
                           message: "Pick a target and press Compare (⌘↩). The generated migration makes the target look like the source.") {
                    Button("Compare") { Task { await model.compare() } }
                        .disabled(!model.canCompare)
                }
            }
        }
    }
}

/// Result state when source and target have no difference.
struct IdenticalSchemasView: View {
    @ObservedObject var model: SchemaDiffModel
    let result: SchemaDiffResult

    var body: some View {
        let n = result.unchangedTables.count
        EmptyState("Schemas are identical", systemImage: "checkmark.seal",
                   message: "\(n) \(n == 1 ? "table" : "tables") compared, nothing to migrate.\n\(model.comparedLabels.source)  →  \(model.comparedLabels.target)") {
            Button("Compare Again") { Task { await model.compare() } }
                .disabled(!model.canCompare)
        }
    }
}

struct ProductionBanner: View {
    let connection: ConnectionConfig

    var body: some View {
        let prod = connection.environment == .production
        Banner(prod ? .error : .warning,
               "Target is \(prod ? "production" : "staging") (\(connection.name)). Review every statement before running this migration; destructive changes stay commented out unless you enable them.")
            // Banner text is vertically fixed-size: a min width keeps it from being measured one word per line.
            .frame(minWidth: 420)
            .padding(.horizontal, DS.Space.l)
            .padding(.top, DS.Space.m)
    }
}

struct SchemaDiffHeader: View {
    @ObservedObject var model: SchemaDiffModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(compact: false)
            row(compact: true)
        }
        .controlSize(.small)
        .padding(.horizontal, DS.Space.l)
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .background(DS.Palette.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// `compact` drops the eyebrow labels and the source chip and narrows the pickers.
    private func row(compact: Bool) -> some View {
        HStack(spacing: DS.Space.m) {
            if !compact {
                eyebrow("Source")
                ConnectionChip(connection: model.context.connection)
            }
            Picker("Source Schema", selection: $model.sourceSchema) {
                ForEach(model.sourceSchemas, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(width: compact ? 110 : 130)
            .help("Source schema (\(model.context.connection.name))")

            Button { model.swap() } label: {
                Image(systemName: compact ? "arrow.right" : "arrow.left.arrow.right").font(.system(size: 11, weight: .medium))
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.targetIsCurrent ? Color.secondary : Color(nsColor: .tertiaryLabelColor))
            .disabled(!model.targetIsCurrent)
            .help("Swap source and target schemas")

            if !compact {
                eyebrow("Target")
                    .help("The target is the side that will be migrated")
            }
            Picker("Target Connection", selection: $model.targetConnectionID) {
                Text("\(model.context.connection.name) (current)").tag(UUID?.none)
                if !model.otherConnections.isEmpty {
                    Divider()
                    ForEach(model.otherConnections) { c in
                        Text("\(c.name) — \(c.environment.displayName)").tag(UUID?.some(c.id))
                    }
                }
            }
            .labelsHidden()
            .frame(width: compact ? 170 : 200)
            .help("Target connection (will be migrated)")
            Picker("Target Schema", selection: $model.targetSchema) {
                ForEach(model.targetSchemas, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(width: compact ? 110 : 130)
            .disabled(model.loadingTargetSchemas)
            if model.loadingTargetSchemas { ProgressView().controlSize(.mini) }

            Spacer(minLength: DS.Space.m)

            Button {
                Task { await model.compare() }
            } label: {
                HStack(spacing: 5) {
                    if model.isComparing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    Text("Compare").fixedSize()
                }
                .frame(minWidth: 72)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canCompare)
            .help("Compare (⌘↩)")
        }
    }

    private func eyebrow(_ s: String) -> some View {
        Text(s.uppercased()).font(DS.Typo.eyebrow).tracking(0.6).foregroundStyle(.secondary).fixedSize()
    }
}

struct ConnectionChip: View {
    let connection: ConnectionConfig

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(connection.accentColor).frame(width: 7, height: 7)
            Text(connection.name.isEmpty ? connection.subtitle : connection.name).font(DS.Typo.callout).lineLimit(1)
        }
        .fixedSize()
        .padding(.horizontal, DS.Space.m)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).strokeBorder(DS.Palette.separator.opacity(0.6), lineWidth: 0.5))
        .help(connection.subtitle)
    }
}

/// Fixed-size filter control: All / + / − / ~ with counts, colored per change.
struct ChangeFilterControl: View {
    @Binding var selection: DiffChange?
    let total: Int
    let count: (DiffChange) -> Int

    var body: some View {
        HStack(spacing: 2) {
            segment(nil) {
                Text("All").font(.system(size: 11.5, weight: selection == nil ? .semibold : .regular))
                Text("\(total)").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            }
            ForEach(DiffChange.allCases, id: \.self) { c in
                segment(c) {
                    Circle().fill(c.color).frame(width: 6, height: 6)
                    Text("\(count(c))").font(.system(size: 11.5, weight: selection == c ? .semibold : .regular)).monospacedDigit()
                }
                .help(c.title)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06)))
        .fixedSize()
    }

    private func segment<C: View>(_ value: DiffChange?, @ViewBuilder content: () -> C) -> some View {
        let on = selection == value
        return HStack(spacing: 4) { content() }
            .lineLimit(1)
            .foregroundStyle(on ? Color.primary : Color.secondary)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background {
                if on {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .shadow(color: .black.opacity(0.12), radius: 0.5, y: 0.5)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { selection = value }
    }
}

struct DiffChangeList: View {
    @ObservedObject var model: SchemaDiffModel
    let result: SchemaDiffResult

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                ToolSearchField(prompt: "Filter changes", text: $model.filterText, width: nil)
                ChangeFilterControl(selection: $model.changeFilter, total: model.allItems.count, count: model.count)
            }
            .padding(DS.Space.l)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(DiffItem.Kind.allCases, id: \.self) { kind in
                        let rows = model.items.filter { $0.kind == kind }
                        if !rows.isEmpty {
                            Section {
                                ForEach(rows) { row($0) }
                            } header: {
                                SectionLabel(kind.title, count: rows.count)
                                    .padding(.horizontal, DS.Space.l)
                                    .frame(height: 26)
                                    .background(DS.Palette.bar)
                            }
                        }
                    }
                    if model.items.isEmpty {
                        Text("No change matches the filter").font(DS.Typo.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.top, DS.Space.xxl)
                    }
                }
                .padding(.bottom, DS.Space.s)
            }
            StatusBar {
                Text("\(result.unchangedTables.count) unchanged table\(result.unchangedTables.count == 1 ? "" : "s")").monospacedDigit()
            }
        }
    }

    func row(_ item: DiffItem) -> some View {
        let selected = model.selection == item.id
        return HStack(spacing: DS.Space.m) {
            Image(systemName: item.symbol).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(DS.Typo.body).lineLimit(1).truncationMode(.middle)
                if !item.summary.isEmpty {
                    Text(item.summary).font(DS.Typo.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: DS.Space.xs)
            ChangeBadge(change: item.change)
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
            .fill(selected ? Color.accentColor.opacity(0.16) : Color.clear))
        .padding(.horizontal, DS.Space.s)
        .contentShape(Rectangle())
        .onTapGesture { model.selection = item.id }
    }
}

struct DiffDetailPane: View {
    @ObservedObject var model: SchemaDiffModel

    var body: some View {
        if let item = model.selectedItem {
            let ddl = model.ddl(for: item)
            VStack(spacing: 0) {
                HStack(spacing: DS.Space.m) {
                    Image(systemName: item.symbol).font(.system(size: 12)).foregroundStyle(.secondary)
                    Text(item.name).font(DS.Typo.headline).lineLimit(1)
                    ChangeBadge(change: item.change)
                    if !item.summary.isEmpty {
                        Text(item.summary).font(DS.Typo.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DS.Space.l)
                .frame(height: 36)
                if item.kind == .table, let t = model.result?.table(item.name), t.change == .changed {
                    TableChangeSummary(diff: t)
                }
                Divider()
                HStack(spacing: 0) {
                    ddlColumn(title: "Source", subtitle: model.comparedLabels.source, text: ddl.source)
                    Divider()
                    ddlColumn(title: "Target", subtitle: model.comparedLabels.target, text: ddl.target)
                }
            }
        } else {
            EmptyState("Select a change", systemImage: "sidebar.left")
        }
    }

    func ddlColumn(title: String, subtitle: String, text: String) -> some View {
        VStack(spacing: 0) {
            SectionLabel(title) {
                Text(subtitle).font(DS.Typo.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, DS.Space.l)
            .frame(height: 26)
            .background(DS.Palette.bar)
            .overlay(alignment: .bottom) { Divider() }
            CodeView(text, language: .sql)
        }
    }
}

/// Column / index / constraint changes of one table.
struct TableChangeSummary: View {
    let diff: TableDiff

    struct Line: Identifiable {
        var id: String
        var change: DiffChange
        var kind: String
        var name: String
        var detail: String
    }

    var lines: [Line] {
        var out: [Line] = []
        for c in diff.columns {
            out.append(Line(id: "c.\(c.name)", change: c.change, kind: "column", name: c.name, detail: c.summary))
        }
        for i in diff.indexes {
            let detail: String
            if let old = i.renamedFrom { detail = "renamed from \(old)" }
            else { detail = (i.source ?? i.target).map { SQLNormalizer.indexBody($0) } ?? "" }
            out.append(Line(id: "i.\(i.name)", change: i.change, kind: "index", name: i.name, detail: detail))
        }
        for c in diff.constraints {
            let detail = c.renamedFrom.map { "renamed from \($0)" } ?? (c.source ?? c.target)?.definition ?? ""
            out.append(Line(id: "k.\(c.name)", change: c.change, kind: c.kind.rawValue.lowercased(), name: c.name, detail: detail))
        }
        return out
    }

    var body: some View {
        let all = lines
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            ForEach(all.prefix(8)) { l in
                HStack(spacing: DS.Space.m) {
                    Text(l.change.symbol)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(nsColor: l.change.nsColor.readableText()))
                        .frame(width: 16, height: 16)
                        .background(RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous).fill(Color(nsColor: l.change.nsColor.softFill())))
                    Text(l.kind).font(DS.Typo.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                    Text(l.name).font(.system(size: 11, weight: .medium, design: .monospaced)).lineLimit(1).fixedSize()
                    Text(l.detail).font(DS.Typo.monoSmall).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                }
            }
            if all.count > 8 {
                Text("and \(all.count - 8) more, see the migration below").font(DS.Typo.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.bottom, DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MigrationPane: View {
    @ObservedObject var model: SchemaDiffModel

    var body: some View {
        let script = model.script
        let destructive = script?.statements.filter { $0.isDestructive && !$0.isNoteOnly }.count ?? 0
        let runnable = script?.executableStatements.count ?? 0
        VStack(spacing: 0) {
            ToolStrip {
                Text("MIGRATION").font(DS.Typo.eyebrow).tracking(0.6).foregroundStyle(.secondary).fixedSize()
                    .padding(.horizontal, DS.Space.xs)
                Text("\(runnable) statement\(runnable == 1 ? "" : "s")").font(DS.Typo.caption).monospacedDigit().foregroundStyle(.secondary).fixedSize()
                if destructive > 0 {
                    Tag("\(destructive) DESTRUCTIVE", color: .systemRed, style: model.options.includeDestructive ? .solid : .soft,
                        systemImage: "exclamationmark.triangle.fill")
                        .help(model.options.includeDestructive ? "Destructive statements are included" : "Destructive statements are commented out")
                }
            } trailing: {
                AskClaudeMenu(context: model.context, title: "Review", items: [
                    AskClaudeItem("Review This Migration", systemImage: "checkmark.shield", disabledReason: (script?.isEmpty ?? true) ? "Nothing to migrate" : nil) {
                        AIRequest(title: "Review migration", prompt: """
                            Review this migration before it runs on the target: locking and downtime risks (table rewrites, \
                            NOT NULL on big tables, non-concurrent indexes), data loss, ordering problems. Give a safer version in one ```sql block if needed.
                            """, attachments: [AIAttachments.sql(model.migrationSQL, title: "Migration")])
                    },
                    AskClaudeItem("Write It as a Kysely Migration", systemImage: "curlybraces", disabledReason: (script?.isEmpty ?? true) ? "Nothing to migrate" : nil) {
                        AIRequest(title: "Kysely migration", prompt: "Rewrite this migration as a Kysely migration file (up and down) in TypeScript.",
                                  attachments: [AIAttachments.sql(model.migrationSQL, title: "Migration")])
                    },
                ])
                MigrationOptionsControl(options: $model.options)
                ToolDivider()
                ToolButton("Copy", systemImage: "doc.on.doc") { model.copyMigration() }
                ToolButton("Save…", systemImage: "square.and.arrow.down") { model.saveMigration() }
                ToolButton("Query Tab", systemImage: "terminal") { model.openInQueryTab() }
                    .disabled(!model.comparedTargetIsCurrent || (script?.isEmpty ?? true))
                    .help(model.comparedTargetIsCurrent ? "Open the script in a new query tab of this connection (not executed)"
                                                        : "The target is another connection: copy or save the script and run it there")
            }
            CodeView(model.migrationSQL, language: .sql)
        }
    }
}

/// Destructive / transaction switches: checkboxes when there is room, an "Options" menu otherwise.
struct MigrationOptionsControl: View {
    @Binding var options: MigrationOptions
    @Environment(\.toolStripCompact) private var compact

    var body: some View {
        if compact {
            Menu {
                Toggle("Include Destructive Changes", isOn: $options.includeDestructive)
                Toggle("Wrap in BEGIN / COMMIT", isOn: $options.wrapInTransaction)
            } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 11.5, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Migration options")
        } else {
            HStack(spacing: DS.Space.l) {
                Toggle("Destructive", isOn: $options.includeDestructive)
                    .foregroundStyle(options.includeDestructive ? Color(nsColor: NSColor.systemRed.readableText()) : Color.primary)
                    .help("Include destructive changes (DROP…); otherwise they stay commented out")
                Toggle("BEGIN / COMMIT", isOn: $options.wrapInTransaction)
                    .help("Wrap the script in a transaction")
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .font(DS.Typo.callout)
            .fixedSize()
            .padding(.horizontal, DS.Space.xs)
        }
    }
}
