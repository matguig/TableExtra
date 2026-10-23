import AppKit
import FeatureAI
import FeatureDataTransfer
import FeatureSchemaTools
import MTPCore
import MTPUIKit
import SwiftUI

struct TableTabView: View {
    @Bindable var tab: TableTabModel
    var workspace: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            switch tab.mode {
            case .data:
                if tab.showFilters {
                    FilterBar(tab: tab)
                } else if !tab.activeFilters.isEmpty {
                    ActiveFilterChips(tab: tab)
                }
                ZStack {
                    TableGridRepresentable(tab: tab)
                    if let error = tab.errorMessage {
                        VStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                            Text(error).multilineTextAlignment(.center).textSelection(.enabled)
                            Button("Retry") { Task { await tab.reloadAll() } }
                        }
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    } else if tab.isLoading && tab.rows.isEmpty {
                        ProgressView().controlSize(.small)
                    } else if tab.rows.isEmpty && tab.displayRowCount == 0 {
                        emptyTable
                    }
                }
                statusBar
            case .structure:
                StructureView(tab: tab, workspace: workspace)
            }
        }
        .sheet(item: $tab.editingValue) { req in
            ValueEditorSheet(request: req) { edit in
                if let edit { tab.setValue(edit, row: req.row, column: req.column) }
                tab.editingValue = nil
            }
        }
    }

    @ViewBuilder
    private var emptyTable: some View {
        if hasActiveFilters {
            EmptyState("No rows match", systemImage: "line.3.horizontal.decrease.circle",
                       message: "None of the rows in \(tab.object.name) satisfy the current filters.") {
                Button("Clear Filters") {
                    tab.filters = []
                    tab.showFilters = false
                    Task { await tab.applyFilters() }
                }
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.9))
        } else {
            EmptyState("\(tab.object.name) is empty", systemImage: "tablecells",
                       message: tab.offset > 0 ? "No rows past offset \(tab.offset)." : "This \(tab.object.kind == .table ? "table" : "view") has no rows yet.") {
                if tab.isEditable { Button("Add Row") { tab.addRow() }.keyboardShortcut("i", modifiers: .command) }
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.9))
        }
    }

    // MARK: Claude

    private var qualified: String { workspace.dialect.qualified(schema: tab.object.schema, name: tab.object.name) }

    /// Table definition when loaded, else the column list of the current page.
    private var schemaAttachment: AIAttachment {
        if let d = tab.details { return AIAttachments.table(d, dialect: workspace.dialect) }
        let cols = tab.columns.map { "\($0.name) \($0.typeName)" }.joined(separator: "\n")
        return AIAttachments.text(cols, title: tab.object.qualifiedName, systemImage: "tablecells")
    }

    private var hasRepo: Bool { workspace.connection.codeRepositoryURL != nil }

    private var claudeItems: [AskClaudeItem] {
        let name = tab.object.name
        let schema = schemaAttachment
        let codeHint = hasRepo ? " Look up in the code repository where and how it is used (models, queries, jobs) and cite files." : ""
        var items: [AskClaudeItem] = []
        if tab.mode == .structure {
            items.append(AskClaudeItem("Explain This Table", systemImage: "text.book.closed") {
                AIRequest(title: "Explain \(name)", prompt: "Explain what the table \(self.qualified) stores, what each column means and how it relates to other tables.\(codeHint)",
                          attachments: [schema], focus: name)
            })
            items.append(AskClaudeItem("Review the Schema", systemImage: "checklist") {
                AIRequest(title: "Review \(name)", prompt: """
                    Review the design of \(self.qualified): column types, nullability, defaults, constraints, foreign keys, naming. \
                    List concrete problems by priority and give the ALTER statements to fix them in one ```sql block.
                    """, attachments: [schema], focus: name)
            })
            items.append(AskClaudeItem("Suggest Indexes", systemImage: "bolt.horizontal") {
                AIRequest(title: "Indexes for \(name)", prompt: """
                    Suggest indexes for \(self.qualified) given its columns, foreign keys and existing indexes (with their scan counts). \
                    Flag redundant or unused indexes.\(self.hasRepo ? " Base it on the queries the application code runs on this table." : "") \
                    Put CREATE INDEX CONCURRENTLY / DROP INDEX statements in one ```sql block.
                    """, attachments: [schema], focus: name)
            })
            items.append(AskClaudeItem("Where Is It Used in the Code?", systemImage: "folder",
                                       disabledReason: hasRepo ? nil : "Set a code repository in the connection settings") {
                AIRequest(title: "\(name) in code", prompt: "Find where the application code reads or writes \(self.qualified) and summarize each usage with file paths.",
                          attachments: [schema], focus: name)
            })
            items.append(AskClaudeItem("Write a Migration…", systemImage: "arrow.triangle.branch") {
                AIRequest(title: "Migration for \(name)", prompt: "Write a migration for \(self.qualified) that ", attachments: [schema],
                          focus: name, autoSend: false)
            })
        } else {
            let page = AIAttachments.rows(title: "\(name) — page \(tab.pageNumber)", columns: tab.columns, rows: tab.rows)
            items.append(AskClaudeItem("Explain This Table", systemImage: "text.book.closed") {
                AIRequest(title: "Explain \(name)", prompt: "Explain what \(self.qualified) stores and what each column means, using the sample rows.\(codeHint)",
                          attachments: [schema, AIAttachments.rows(title: "\(name) — sample", columns: self.tab.columns, rows: self.tab.rows, limit: 15)], focus: name)
            })
            items.append(AskClaudeItem("Summarize These Rows", systemImage: "list.bullet.rectangle") {
                AIRequest(title: "Summarize \(name)", prompt: """
                    Summarize the attached rows of \(self.qualified)\(self.tab.lastSQL.isEmpty ? "" : " (loaded with: \(self.tab.lastSQL))"): \
                    distributions, outliers, suspicious or NULL-heavy values. Keep it short.
                    """, attachments: [schema, page], focus: name)
            })
            if !tab.selectedRows.isEmpty {
                let selected = tab.selectedRows.sorted().compactMap { $0 < tab.rows.count ? tab.rows[$0] : nil }
                items.append(AskClaudeItem("Explain the Selected Rows", systemImage: "rectangle.and.hand.point.up.left") {
                    AIRequest(title: "\(selected.count) row\(selected.count == 1 ? "" : "s") of \(name)",
                              prompt: "Explain these rows of \(self.qualified): what they represent and anything unusual. Suggest queries to find related rows.",
                              attachments: [schema, AIAttachments.rows(title: "Selected rows", columns: self.tab.columns, rows: selected)], focus: name)
                })
            }
            items.append(AskClaudeItem("Write a Query on This Table…", systemImage: "square.and.pencil") {
                AIRequest(title: "Query on \(name)", prompt: "", attachments: [schema], focus: name, autoSend: false)
            })
        }
        return items
    }

    private var hasActiveFilters: Bool {
        tab.filters.contains { $0.isEnabled && !$0.value.isEmpty || !$0.op.needsValue }
    }

    private var toolbar: some View {
        ToolStrip {
            CompactSegmented([(label: "Data", value: TableTabMode.data), (label: "Structure", value: TableTabMode.structure)], selection: $tab.mode)
                .padding(.trailing, DS.Space.s)
            if tab.mode == .data {
                ToolButton(tab.activeFilters.isEmpty ? "Filter" : "Filter · \(tab.activeFilters.count)",
                           systemImage: hasActiveFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease", shortcut: "⇧⌘F") {
                    tab.showFilters.toggle()
                    if tab.showFilters && tab.filters.isEmpty { tab.filters = [FilterRule(column: tab.columns.first?.name)] }
                }
                ToolButton("Reload", systemImage: "arrow.clockwise", shortcut: "⌥⌘R") { Task { await tab.loadPage() } }
                if tab.isEditable {
                    ToolDivider()
                    ToolButton("Add Row", systemImage: "plus", shortcut: "⌘I") { tab.addRow() }
                    ToolButton("Delete", systemImage: "trash", shortcut: "⌘⌫") { tab.deleteRows(tab.selectedRows) }
                        .disabled(tab.selectedRows.isEmpty)
                } else if tab.object.kind == .table {
                    Tag(workspace.connection.safety == .readOnly ? "READ-ONLY" : "NO PRIMARY KEY", color: .systemGray, systemImage: "lock.fill")
                        .help(workspace.connection.safety == .readOnly ? "Read-only connection" : "Rows can't be edited without a primary key")
                }
            }
        } trailing: {
            AskClaudeMenu(context: workspace, items: claudeItems)
            if tab.hasUnsavedChanges {
                Tag("\(tab.changes.count) CHANGE\(tab.changes.count == 1 ? "" : "S")", color: .systemOrange)
                ToolButton("Preview", systemImage: "eye", shortcut: "⇧⌘P") {
                    workspace.sheet = .preview(title: "Pending changes — \(tab.object.name)", sql: tab.previewSQL())
                }
                ToolButton("Discard", systemImage: "arrow.uturn.backward", shortcut: "⇧⌘⌫") { tab.discard() }
                Button { Task { await tab.commit() } } label: { Text("Commit").fontWeight(.semibold).padding(.horizontal, 4) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(workspace.connection.isProductionLike ? .red : .accentColor)
                    .help("Commit changes (⌘S)")
            }
            Menu {
                Button("Export…") { workspace.sheet = .export(.tables(schema: tab.object.schema, names: [tab.object.name])) }
                Button("Export Current Page…") { workspace.sheet = .export(.result(tab.selectedResult(), suggestedName: tab.object.name, tableName: tab.object.name)) }
                Button("Import CSV…") { workspace.sheet = .importCSV(schema: tab.object.schema, table: tab.object.name) }
                Divider()
                Button("Copy SELECT Statement") { Pasteboard.copy(tab.lastSQL) }
                Button("Open SELECT in Query Tab") { workspace.openQueryTab(title: tab.object.name, sql: tab.lastSQL + ";", run: false) }
                Button("Kysely / TypeScript Type…") { workspace.openFeature(.typeScript(schema: tab.object.schema, tables: [tab.object.name])) }
                Button("Count Rows Exactly") { Task { await tab.refreshCount(forceExact: true) } }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.horizontal, DS.Space.xs)
        }
    }

    private var statusBar: some View {
        StatusBar {
            if tab.isEditable {
                Button { tab.addRow() } label: { Label("Add Row", systemImage: "plus").labelStyle(.titleAndIcon) }
                    .buttonStyle(.borderless)
                    .help("Add row (⌘I)")
                Divider().frame(height: 12)
            }
            if tab.isLoading { ProgressView().controlSize(.mini) }
            let start = tab.rows.isEmpty ? 0 : tab.offset + 1
            Text("\(Fmt.count(Int64(start)))–\(Fmt.count(Int64(tab.offset + tab.rows.count))) of \(tab.totalCount.map { (tab.countIsEstimate ? "~" : "") + Fmt.count($0) } ?? "?") rows")
                .monospacedDigit()
                .help(tab.countIsEstimate ? "Planner estimate — use ••• → Count Rows Exactly" : "")
            Text(Fmt.duration(tab.lastDuration)).foregroundStyle(.tertiary).monospacedDigit()
            Text(tab.lastSQL).truncationMode(.middle).foregroundStyle(.tertiary).textSelection(.enabled)
                .frame(maxWidth: 420, alignment: .leading)
        } trailing: {
            HStack(spacing: DS.Space.xs) {
                Button { Task { await tab.previousPage() } } label: { Image(systemName: "chevron.left").frame(width: 18, height: 18).contentShape(Rectangle()) }
                    .disabled(tab.offset == 0)
                Text("\(tab.pageNumber)\(tab.pageCount.map { " / \($0)" } ?? "")").monospacedDigit().frame(minWidth: 44)
                Button { Task { await tab.nextPage() } } label: { Image(systemName: "chevron.right").frame(width: 18, height: 18).contentShape(Rectangle()) }
                    .disabled(tab.rows.count < tab.pageSize)
            }
            .buttonStyle(.borderless)
            Menu("\(tab.pageSize) / page") {
                ForEach([100, 300, 500, 1000, 5000], id: \.self) { n in Button("\(n) rows") { tab.pageSize = n } }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .onChange(of: tab.pageSize) { _, _ in Task { await tab.applyFilters() } }
        }
    }
}

/// DataGridView bound to a TableTabModel.
struct TableGridRepresentable: NSViewRepresentable {
    var tab: TableTabModel

    func makeNSView(context: Context) -> DataGridView {
        let grid = DataGridView(frame: .zero)
        grid.nullText = AppSettings.nullText
        grid.showsRowNumbers = UserDefaults.standard.bool(forKey: SettingKey.showRowNumbers)
        grid.dataSource = tab
        grid.reload()
        context.coordinator.version = tab.dataVersion
        context.coordinator.grid = grid
        context.coordinator.observe(tab)
        return grid
    }

    func updateNSView(_ grid: DataGridView, context: Context) {
        _ = tab.dataVersion
        grid.dataSource = tab
        if context.coordinator.version != tab.dataVersion {
            context.coordinator.version = tab.dataVersion
            grid.reload()
            if !tab.selectedRows.isEmpty, tab.selectedRows != grid.selectedRows, let last = tab.selectedRows.last {
                grid.selectRow(last)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        var version = -1
        weak var grid: DataGridView?

        /// Observation keeps the grid in sync even when SwiftUI does not re-run updateNSView.
        func observe(_ tab: TableTabModel) {
            withObservationTracking {
                _ = tab.dataVersion
            } onChange: { [weak self, weak tab] in
                DispatchQueue.main.async {
                    guard let self, let tab, let grid = self.grid else { return }
                    if self.version != tab.dataVersion {
                        self.version = tab.dataVersion
                        grid.reload()
                    }
                    self.observe(tab)
                }
            }
        }
    }
}

/// Filter conditions above the grid (TablePlus layout, Supabase/AirOps/Calendly details):
/// "Where [column] [operator] [value]", then "and/or" rows; Apply with ↩, Esc closes.
struct FilterBar: View {
    @Bindable var tab: TableTabModel
    @FocusState private var focusedRule: UUID?
    @State private var describe = ""
    @State private var describing = false
    @State private var describeError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            naturalLanguageRow
            ForEach(Array($tab.filters.enumerated()), id: \.element.id) { index, $rule in
                FilterRuleRow(rule: $rule, index: index, tab: tab, focused: $focusedRule,
                              isLast: index == tab.filters.count - 1) {
                    if index == 0 { applyControls } else { Color.clear.frame(height: 1) }
                }
            }
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.s + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.bar)
        .overlay(alignment: .bottom) { Divider() }
        .onAppear { focusedRule = tab.filters.last?.id }
        .onExitCommand { tab.showFilters = false }
    }

    /// "✦ Describe the rows you want" → Claude writes a WHERE condition (schema only, no rows sent) added as a SQL rule.
    private var naturalLanguageRow: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "sparkles").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.accentColor)
                .frame(width: 18)
            TextField("Describe the rows you want — e.g. paid orders over 100 placed last week", text: $describe)
                .textFieldStyle(.plain)
                .font(DS.Typo.callout)
                .onSubmit(runDescribe)
                .disabled(describing)
            if describing {
                ProgressView().controlSize(.small)
            } else if let describeError {
                Text(describeError).font(DS.Typo.caption).foregroundStyle(.red).lineLimit(1).help(describeError)
            }
            if !describe.isEmpty && !describing {
                Button("Filter with Claude", action: runDescribe).controlSize(.small)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).fill(Color.accentColor.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).strokeBorder(Color.accentColor.opacity(0.18), lineWidth: 0.5))
        .padding(.bottom, DS.Space.xs)
    }

    private func runDescribe() {
        let text = describe.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !describing else { return }
        describing = true
        describeError = nil
        Task {
            do {
                let condition = try await AIService.filterCondition(text, schema: tab.object.schema, table: tab.object.name,
                                                                    columns: tab.columns, context: tab.workspace)
                // Replace an empty starter rule, otherwise add the condition next to the existing ones.
                if tab.filters.count == 1, tab.filters[0].value.isEmpty, tab.filters[0].op.needsValue { tab.filters = [] }
                tab.filters.append(FilterRule(column: nil, op: .raw, value: condition))
                describe = ""
                await tab.applyFilters()
            } catch {
                describeError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            describing = false
        }
    }

    private var applyControls: some View {
        HStack(spacing: DS.Space.s) {
            Button("Clear") {
                tab.filters = [FilterRule(column: tab.columns.first?.name)]
                Task { await tab.applyFilters() }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            Button { Task { await tab.applyFilters() } } label: {
                HStack(spacing: 5) {
                    Text("Apply").fontWeight(.semibold)
                    Text("↩").opacity(0.7)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).fill(Color.accentColor))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: [])
            .help("Apply filters (↩)")
        }
    }
}

private struct FilterRuleRow<Trailing: View>: View {
    @Binding var rule: FilterRule
    var index: Int
    var tab: TableTabModel
    var focused: FocusState<UUID?>.Binding
    var isLast: Bool
    @ViewBuilder var trailing: Trailing
    @State private var hover = false

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Toggle("", isOn: $rule.isEnabled).labelsHidden().toggleStyle(.checkbox).controlSize(.small)
                .help(rule.isEnabled ? "Disable this condition" : "Enable this condition")
            combinator.frame(width: 48, alignment: .leading)
            columnMenu.frame(width: columnWidth, alignment: .leading)
            operatorMenu.frame(width: 104, alignment: .leading)
            valueFields
            HStack(spacing: 2) {
                iconButton("minus", "Remove condition") {
                    tab.filters.removeAll { $0.id == rule.id }
                    if tab.filters.isEmpty { tab.showFilters = false }
                    Task { await tab.applyFilters() }
                }
                iconButton("plus", "Add condition") {
                    let new = FilterRule(column: rule.column)
                    tab.filters.insert(new, at: index + 1)
                    focused.wrappedValue = new.id
                }
            }
            .opacity(hover || isLast ? 1 : 0.35)
            trailing.frame(width: 118, alignment: .trailing)
        }
        .opacity(rule.isEnabled ? 1 : 0.5)
        .frame(height: 26)
        .onHover { hover = $0 }
    }

    /// "Where" on the first row; on the others a chip that flips AND/OR for the whole filter.
    @ViewBuilder
    private var combinator: some View {
        if index == 0 {
            Text("Where").font(DS.Typo.callout).foregroundStyle(.secondary)
        } else {
            Button { tab.matchAll.toggle() } label: {
                Text(tab.matchAll ? "and" : "or")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.accentColor.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .help("Match all conditions (and) or any of them (or) — click to switch")
        }
    }

    /// Same width on every row so operators and values line up: the longest column name in the chip.
    private var columnWidth: CGFloat {
        let longest = tab.columns.map(\.name.count).max() ?? 10
        return min(260, max(130, CGFloat(longest) * 7.3 + 52))
    }

    private var currentColumn: ResultColumn? { tab.columns.first { $0.name == rule.column } }

    private var columnMenu: some View {
        Menu {
            Button { rule.column = nil } label: { Label("Any column", systemImage: "asterisk") }
            Divider()
            ForEach(tab.columns, id: \.name) { c in
                Button { rule.column = c.name } label: { Label("\(c.name)  \(c.typeName)", systemImage: c.kind.symbolName) }
            }
        } label: {
            FilterChipLabel(icon: currentColumn?.kind.symbolName ?? "asterisk", text: rule.column ?? "Any column", mono: true)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(currentColumn.map { "\($0.name) — \($0.typeName)" } ?? "Search every column")
    }

    private var operatorMenu: some View {
        Menu {
            ForEach(FilterOperatorUI.groups, id: \.0) { group in
                Section(group.0) {
                    ForEach(group.1) { op in
                        Button { rule.op = op } label: {
                            if op == rule.op { Label(FilterOperatorUI.title(op), systemImage: "checkmark") } else { Text(FilterOperatorUI.title(op)) }
                        }
                    }
                }
            }
        } label: {
            FilterChipLabel(icon: nil, text: FilterOperatorUI.short(rule.op), mono: FilterOperatorUI.isSymbol(rule.op))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(FilterOperatorUI.title(rule.op))
    }

    @ViewBuilder
    private var valueFields: some View {
        if rule.op.needsValue {
            valueField($rule.value, placeholder: placeholder)
            if rule.op.needsSecondValue {
                Text("and").font(DS.Typo.callout).foregroundStyle(.secondary)
                valueField($rule.value2, placeholder: "Value")
            }
        } else {
            Spacer(minLength: 0)
        }
    }

    private func valueField(_ text: Binding<String>, placeholder: String) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .focused(focused, equals: rule.id)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                .strokeBorder(focused.wrappedValue == rule.id ? Color.accentColor.opacity(0.7) : DS.Palette.separator, lineWidth: focused.wrappedValue == rule.id ? 1.5 : 0.5))
            .frame(minWidth: 120, maxWidth: .infinity)
            .onSubmit { Task { await tab.applyFilters() } }
    }

    private var placeholder: String {
        switch rule.op {
        case .raw: return "SQL condition, e.g. total > 100 AND status = 'paid'"
        case .isIn, .notIn: return "a, b, c"
        case .regex: return "Regular expression"
        case .like, .notLike: return "Pattern, e.g. %@example.com"
        default:
            switch currentColumn?.kind {
            case .integer, .decimal: return "Number"
            case .date: return "YYYY-MM-DD"
            case .timestamp: return "YYYY-MM-DD HH:MM"
            case .boolean: return "true / false"
            case .uuid: return "UUID"
            default: return "Value"
            }
        }
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.06)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

}

/// Labels for filter operators: a compact chip text and a menu title with the SQL it maps to.
enum FilterOperatorUI {
    static let groups: [(String, [FilterOperator])] = [
        ("Comparison", [.equals, .notEquals, .greater, .less, .greaterOrEqual, .lessOrEqual]),
        ("Text", [.contains, .containsCaseInsensitive, .notContains, .startsWith, .endsWith, .like, .notLike, .regex]),
        ("Empty", [.isNull, .isNotNull, .isEmpty, .isNotEmpty]),
        ("List & Range", [.isIn, .notIn, .between, .notBetween]),
        ("Advanced", [.raw]),
    ]

    static func isSymbol(_ op: FilterOperator) -> Bool {
        [.equals, .notEquals, .less, .greater, .lessOrEqual, .greaterOrEqual].contains(op)
    }

    /// Compact label shown in the chip.
    static func short(_ op: FilterOperator) -> String {
        switch op {
        case .notEquals: return "≠"
        case .lessOrEqual: return "≤"
        case .greaterOrEqual: return "≥"
        case .containsCaseInsensitive: return "contains (any case)"
        case .startsWith: return "starts with"
        case .endsWith: return "ends with"
        case .isNull: return "is NULL"
        case .isNotNull: return "is not NULL"
        case .isEmpty: return "is empty"
        case .isNotEmpty: return "is not empty"
        case .isIn: return "in"
        case .notIn: return "not in"
        case .between: return "between"
        case .notBetween: return "not between"
        case .regex: return "matches"
        case .raw: return "SQL"
        case .contains: return "contains"
        case .notContains: return "doesn't contain"
        default: return op.rawValue
        }
    }

    /// Menu title: friendly name plus the SQL it maps to (Supabase-style hint).
    static func title(_ op: FilterOperator) -> String {
        switch op {
        case .equals: return "Equals   ="
        case .notEquals: return "Not equal   <>"
        case .greater: return "Greater than   >"
        case .less: return "Less than   <"
        case .greaterOrEqual: return "Greater or equal   >="
        case .lessOrEqual: return "Less or equal   <="
        case .contains: return "Contains"
        case .containsCaseInsensitive: return "Contains, any case   ILIKE"
        case .notContains: return "Does not contain"
        case .startsWith: return "Starts with"
        case .endsWith: return "Ends with"
        case .like: return "Like   LIKE"
        case .notLike: return "Not like   NOT LIKE"
        case .regex: return "Matches regex   ~"
        case .isNull: return "Is NULL"
        case .isNotNull: return "Is not NULL"
        case .isEmpty: return "Is empty (NULL or '')"
        case .isNotEmpty: return "Is not empty"
        case .isIn: return "In list   IN"
        case .notIn: return "Not in list   NOT IN"
        case .between: return "Between   BETWEEN"
        case .notBetween: return "Not between"
        case .raw: return "Raw SQL condition"
        }
    }
}

/// Rounded chip used for the column and operator pickers.
private struct FilterChipLabel: View {
    var icon: String?
    var text: String
    var mono: Bool
    @State private var hover = false

    var body: some View {
        HStack(spacing: 5) {
            if let icon { Image(systemName: icon).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.tertiary) }
            Text(text).font(mono ? .system(size: 12, design: .monospaced) : .system(size: 12)).lineLimit(1)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 7.5, weight: .bold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).fill(hover ? DS.Palette.pressed : Color.primary.opacity(0.06)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

/// Applied filters as removable chips when the filter bar is closed (Browserbase-style), so the grid never
/// looks unfiltered by mistake.
struct ActiveFilterChips: View {
    @Bindable var tab: TableTabModel

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "line.3.horizontal.decrease").font(.system(size: 11)).foregroundStyle(.secondary)
            ForEach(Array(tab.activeFilters.enumerated()), id: \.element.id) { i, rule in
                if i > 0 { Text(tab.matchAll ? "and" : "or").font(DS.Typo.caption).foregroundStyle(.tertiary) }
                chip(rule)
            }
            Spacer(minLength: 0)
            Button("Clear filters") {
                tab.filters = []
                tab.showFilters = false
                Task { await tab.applyFilters() }
            }
            .buttonStyle(.borderless)
            .font(DS.Typo.callout)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, DS.Space.l)
        .frame(height: 32)
        .background(DS.Palette.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func chip(_ rule: FilterRule) -> some View {
        HStack(spacing: 0) {
            Button { tab.showFilters = true } label: {
                HStack(spacing: 4) {
                    Text(rule.column ?? "any column").foregroundStyle(.primary)
                    Text(FilterOperatorUI.short(rule.op)).foregroundStyle(.secondary)
                    if rule.op.needsValue {
                        Text(rule.op.needsSecondValue ? "\(rule.value) – \(rule.value2)" : rule.value)
                            .foregroundStyle(Color.accentColor).lineLimit(1)
                    }
                }
                .font(.system(size: 11.5, design: .monospaced))
                .padding(.leading, 8)
                .padding(.trailing, 4)
                .frame(height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Edit filters")
            Button {
                tab.filters.removeAll { $0.id == rule.id }
                Task { await tab.applyFilters() }
            } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: 18, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove this condition")
        }
        .background(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).fill(Color.accentColor.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 0.5))
        .fixedSize()
    }
}

/// Large values (JSON, long text): edit in a sheet with JSON formatting helpers.
struct ValueEditorSheet: View {
    let request: TableTabModel.ValueEditRequest
    var onDone: (CellEdit?) -> Void
    @State private var text = ""
    @State private var isNull = false
    @State private var jsonError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(request.columnName).font(.headline)
                Text(request.typeName).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if request.isJSON || looksLikeJSON {
                    Button("Format JSON") { reformat(pretty: true) }
                    Button("Minify") { reformat(pretty: false) }
                }
            }
            CodeView(text: $text, language: request.isJSON || looksLikeJSON ? .json : .plain, isEditable: !request.readOnly && !isNull)
                .frame(minHeight: 260)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.3)))
            if let jsonError { Text(jsonError).font(.caption).foregroundStyle(.red) }
            HStack {
                if !request.readOnly { Toggle("NULL", isOn: $isNull) }
                Text("\(text.count) characters").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Copy") { Pasteboard.copy(text) }
                Button("Cancel") { onDone(nil) }.keyboardShortcut(.cancelAction)
                if !request.readOnly {
                    Button("Save") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 380)
        .onAppear {
            text = request.value ?? ""
            isNull = request.value == nil
            if request.isJSON { reformat(pretty: true) }
        }
    }

    private var looksLikeJSON: Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("{") || t.hasPrefix("[")
    }

    private func reformat(pretty: Bool) {
        guard let data = text.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            jsonError = text.isEmpty ? nil : "Not valid JSON"
            return
        }
        jsonError = nil
        let opts: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.withoutEscapingSlashes]
        if let out = try? JSONSerialization.data(withJSONObject: obj, options: opts.union(.fragmentsAllowed)), let s = String(data: out, encoding: .utf8) {
            text = s
        }
    }

    private func save() {
        if isNull { onDone(.null); return }
        if request.isJSON {
            guard let data = text.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else {
                jsonError = "Not valid JSON — fix it or cancel"
                return
            }
            reformat(pretty: false)
        }
        onDone(.value(text))
    }
}
