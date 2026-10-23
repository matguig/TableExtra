import MTPCore
import MTPUIKit
import SwiftUI

/// Columns, indexes, constraints, triggers and DDL of a table/view (TablePlus "Structure" tab),
/// plus SQL generators for common ALTERs that open in a query tab instead of running blindly.
struct StructureView: View {
    var tab: TableTabModel
    var workspace: WorkspaceModel
    @State private var section = "Columns"
    @State private var ddl = ""

    var body: some View {
        VStack(spacing: 0) {
            metadata
            ToolStrip {
                CompactSegmented(sections, selection: $section)
            } trailing: {
                Menu {
                    Button("Add Column…") { openSQL("ALTER TABLE \(qualified) ADD COLUMN new_column text;") }
                    Button("Add Index…") { openSQL("CREATE INDEX\(workspace.isPostgres ? " CONCURRENTLY" : "") \(tab.object.name)_col_idx ON \(qualified) (column_name);") }
                    Button("Add Foreign Key…") { openSQL("ALTER TABLE \(qualified) ADD CONSTRAINT \(tab.object.name)_fk FOREIGN KEY (column_name) REFERENCES other_table (id);") }
                    Divider()
                    Button("Rename Table…") { openSQL("ALTER TABLE \(qualified) RENAME TO new_name;") }
                    Button("Truncate…") { openSQL("TRUNCATE TABLE \(qualified);") }
                    Button("Drop Table…") { openSQL("DROP TABLE \(qualified);") }
                } label: {
                    Label("Alter", systemImage: "hammer")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Generate ALTER statements in a new query tab")
            }
            if let d = tab.details {
                switch section {
                case "Columns": columns(d)
                case "Indexes": indexes(d)
                case "Constraints": constraints(d)
                case "Triggers": triggers(d)
                default:
                    CodeView(ddl)
                        .task(id: tab.object.id) {
                            ddl = (try? await workspace.introspector.ddl(for: tab.object)) ?? DDLWriter.createTable(d, dialect: workspace.dialect)
                        }
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Object summary above the tabs: qualified name, then chips (kind, rows, size, columns, keys) and the comment.
    private var metadata: some View {
        let o = tab.object
        let d = tab.details
        return VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Text(o.schema).font(DS.Typo.callout).foregroundStyle(.secondary)
                Text("/").font(DS.Typo.callout).foregroundStyle(.tertiary)
                Text(o.name).font(.system(size: 14, weight: .semibold)).textSelection(.enabled)
            }
            HStack(spacing: DS.Space.xs) {
                chip(o.kind.sectionTitle.hasSuffix("s") ? String(o.kind.sectionTitle.dropLast()) : o.kind.sectionTitle, o.kind.symbolName)
                if let n = o.estimatedRows { chip("~\(Fmt.compact(n)) rows", "list.number") }
                if let b = o.sizeBytes { chip(Fmt.bytes(b), "internaldrive") }
                if let d {
                    chip("\(d.columns.count) columns", "tablecells")
                    if !d.primaryKey.isEmpty { chip("PK " + d.primaryKey.joined(separator: ", "), "key") }
                    if !d.foreignKeys.isEmpty { chip("\(d.foreignKeys.count) FK", "link") }
                }
            }
            if let comment = o.comment, !comment.isEmpty {
                Text(comment).font(DS.Typo.callout).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            }
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func chip(_ text: String, _ icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.tertiary)
            Text(text).font(DS.Typo.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(RoundedRectangle(cornerRadius: DS.Radius.s + 1, style: .continuous).fill(Color.primary.opacity(0.05)))
        .fixedSize()
    }

    private var sections: [(label: String, value: String)] {
        let d = tab.details
        func label(_ name: String, _ n: Int?) -> String { n.map { "\(name)  \($0)" } ?? name }
        return [
            (label("Columns", d?.columns.count), "Columns"),
            (label("Indexes", d?.indexes.count), "Indexes"),
            (label("Constraints", d?.constraints.count), "Constraints"),
            (label("Triggers", d?.triggers.count), "Triggers"),
            ("DDL", "DDL"),
        ]
    }

    private var qualified: String { workspace.dialect.qualified(schema: tab.object.schema, name: tab.object.name) }

    private func openSQL(_ sql: String) {
        workspace.openQueryTab(title: "Alter \(tab.object.name)", sql: sql, run: false)
    }

    private func columns(_ d: TableDetails) -> some View {
        Table(d.columns) {
            TableColumn("#") { c in Text("\(c.ordinal)").font(DS.Typo.caption).foregroundStyle(.tertiary).monospacedDigit() }.width(28)
            TableColumn("Name") { c in
                HStack(spacing: 5) {
                    Text(c.name).font(.system(size: 12.5, weight: c.isPrimaryKey ? .semibold : .regular)).textSelection(.enabled)
                    if c.isPrimaryKey { Tag("PK", color: .systemYellow, systemImage: "key.fill") }
                    if c.foreignKey != nil { Tag("FK", color: .systemBlue, systemImage: "link") }
                }
            }
            .width(min: 140, ideal: 200)
            TableColumn("Type") { c in Text(c.dataType).font(DS.Typo.mono).foregroundStyle(MTPColorsSwiftUI.type).lineLimit(1).help(c.dataType) }
                .width(min: 100, ideal: 170)
            TableColumn("Null") { c in
                if c.isNullable { Tag("NULL", color: .systemGray, style: .outline) } else { Text("NOT NULL").font(DS.Typo.micro).foregroundStyle(.secondary) }
            }
            .width(70)
            TableColumn("Default") { c in
                Text(c.isIdentity ? "identity" : (c.defaultValue ?? "")).font(DS.Typo.monoSmall).foregroundStyle(.secondary).lineLimit(1).help(c.defaultValue ?? "")
            }
            .width(min: 80, ideal: 180)
            TableColumn("References") { c in
                if let fk = c.foreignKey {
                    Button("\(fk.refTable).\(fk.refColumns.joined(separator: ","))") { workspace.openTable(schema: fk.refSchema, name: fk.refTable) }
                        .buttonStyle(.link)
                }
            }
            .width(min: 80, ideal: 150)
            TableColumn("Values / Comment") { c in
                Text(c.enumValues.map { $0.joined(separator: " | ") } ?? c.comment ?? "").foregroundStyle(.secondary).lineLimit(1).help(c.comment ?? "")
            }
        }
    }

    private func indexes(_ d: TableDetails) -> some View {
        Table(d.indexes) {
            TableColumn("Name") { i in
                HStack(spacing: 4) {
                    Text(i.name).textSelection(.enabled)
                    if i.isPrimary { Tag("PRIMARY", color: .systemYellow) } else if i.isUnique { Tag("UNIQUE", color: .systemTeal) }
                }
            }
            .width(min: 140, ideal: 220)
            TableColumn("Columns") { i in Text(i.columns.joined(separator: ", ")).font(.system(.body, design: .monospaced)) }.width(min: 100, ideal: 180)
            TableColumn("Method") { i in Text(i.method) }.width(60)
            TableColumn("Size") { i in Text(Fmt.bytes(i.sizeBytes)).monospacedDigit() }.width(70)
            TableColumn("Scans") { i in
                Text(i.scans.map { Fmt.count($0) } ?? "—").monospacedDigit()
                    .foregroundStyle(i.scans == 0 && !i.isPrimary && !i.isUnique ? .orange : .primary)
                    .help(i.scans == 0 ? "Never used since statistics were reset" : "")
            }
            .width(70)
            TableColumn("Definition") { i in Text(i.definition).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).help(i.definition) }
        }
    }

    private func constraints(_ d: TableDetails) -> some View {
        Table(d.constraints) {
            TableColumn("Name") { c in Text(c.name).textSelection(.enabled) }.width(min: 140, ideal: 220)
            TableColumn("Type") { c in Tag(c.kind.rawValue.uppercased(), color: constraintColor(c.kind)) }.width(110)
            TableColumn("Columns") { c in Text(c.columns.joined(separator: ", ")).font(.system(.body, design: .monospaced)) }.width(min: 80, ideal: 160)
            TableColumn("Definition") { c in Text(c.definition).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2).help(c.definition) }
        }
    }

    private func triggers(_ d: TableDetails) -> some View {
        Table(d.triggers) {
            TableColumn("Name") { t in Text(t.name) }.width(min: 120, ideal: 180)
            TableColumn("Timing") { t in Text(t.timing) }.width(90)
            TableColumn("Events") { t in Text(t.events) }.width(min: 80, ideal: 140)
            TableColumn("State") { t in Tag(t.isEnabled ? "ENABLED" : "DISABLED", color: t.isEnabled ? .systemGreen : .systemOrange) }.width(80)
            TableColumn("Definition") { t in Text(t.definition).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2).help(t.definition) }
        }
    }
}

private func constraintColor(_ kind: ConstraintKind) -> NSColor {
    switch kind.rawValue.lowercased() {
    case let k where k.contains("primary"): return .systemYellow
    case let k where k.contains("foreign"): return .systemBlue
    case let k where k.contains("unique"): return .systemTeal
    case let k where k.contains("check"): return .systemPurple
    default: return .systemGray
    }
}

enum MTPColorsSwiftUI {
    static let type = Color(nsColor: MTPColors.identifier)
}

/// Right sidebar: the selected row as a vertical form (TablePlus "Row Detail").
struct RowDetailView: View {
    var tab: TableTabModel
    @State private var search = ""

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: DS.Space.m) {
                SectionLabel("Row") {
                    if let r = tab.selectedRows.first { Text("#\(tab.offset + r + 1)").font(DS.Typo.caption).foregroundStyle(.secondary).monospacedDigit() }
                }
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.tertiary)
                    TextField("Filter fields", text: $search).textFieldStyle(.plain).font(DS.Typo.callout)
                }
                .padding(.horizontal, 7)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).fill(Color.primary.opacity(0.055)))
            }
            .padding(DS.Space.l)
            Divider()
            if let row = tab.selectedRows.first, row < tab.displayRowCount {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DS.Space.l) {
                        ForEach(Array(tab.columns.enumerated()), id: \.offset) { i, col in
                            if search.isEmpty || col.name.localizedCaseInsensitiveContains(search) {
                                RowField(tab: tab, row: row, column: i, col: col)
                            }
                        }
                    }
                    .padding(DS.Space.l)
                }
            } else {
                EmptyState("No row selected", systemImage: "rectangle.and.hand.point.up.left", message: "Select a row in the grid to see and edit its fields here.")
            }
        }
    }
}

private struct RowField: View {
    var tab: TableTabModel
    var row: Int
    var column: Int
    var col: ResultColumn
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        let value = tab.value(row: row, column: column)
        let editable = tab.gridCanEdit(column: column)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(col.name).font(.system(size: 11.5, weight: .medium))
                Text(col.typeName).font(DS.Typo.micro).foregroundStyle(.tertiary)
                Spacer()
                if tab.gridCellState(row: row, column: column) == .edited { Circle().fill(.orange).frame(width: 6, height: 6) }
                Button { tab.gridOpenEditor(row: row, column: column) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.borderless).controlSize(.mini).help("Open editor")
            }
            if col.kind == .json || (value?.count ?? 0) > 80 {
                Text(value ?? AppSettings.nullText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(value == nil ? .tertiary : .primary)
                    .lineLimit(6)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .textBackgroundColor)))
                    .onTapGesture(count: 2) { tab.gridOpenEditor(row: row, column: column) }
            } else {
                TextField(value == nil ? AppSettings.nullText : "", text: $draft)
                    .font(.system(size: 12, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .disabled(!editable)
                    .focused($focused)
                    .onSubmit { commit(value) }
                    .onChange(of: focused) { _, f in if !f { commit(value) } }
            }
        }
        .onAppear { draft = value ?? "" }
        .onChange(of: row) { _, _ in draft = tab.value(row: row, column: column) ?? "" }
        .onChange(of: tab.dataVersion) { _, _ in if !focused { draft = tab.value(row: row, column: column) ?? "" } }
    }

    private func commit(_ original: String?) {
        guard tab.gridCanEdit(column: column) else { return }
        if draft == (original ?? "") && !(original == nil && !draft.isEmpty) { return }
        tab.setValue(.value(draft), row: row, column: column)
    }
}
