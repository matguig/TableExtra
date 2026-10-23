import AppKit
import FeatureAI
import FeatureDataTransfer
import FeatureInsights
import MTPCore
import MTPUIKit
import SwiftUI

struct QueryTabView: View {
    @Bindable var tab: QueryTabModel
    var workspace: WorkspaceModel

    var body: some View {
        HSplitView {
            VSplitView {
                VStack(spacing: 0) {
                    toolbar
                    SQLEditorRepresentable(tab: tab, workspace: workspace)
                        .frame(minHeight: 120)
                }
                .frame(minHeight: 160)
                if tab.showResults {
                    ResultsPane(tab: tab, workspace: workspace)
                        .frame(minHeight: 140)
                }
            }
            .frame(minWidth: 420)
        }
    }

    private var toolbar: some View {
        ToolStrip {
            if tab.isRunning {
                ToolButton("Stop", systemImage: "stop.fill", shortcut: "⌘.", role: .destructive) { tab.cancel() }
                if let since = tab.runningSince {
                    TimelineView(.periodic(from: since, by: 0.5)) { ctx in
                        Text(Fmt.duration(ctx.date.timeIntervalSince(since))).font(DS.Typo.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, DS.Space.xs)
                }
            } else {
                ToolButton(tab.selection.length > 0 ? "Run Selection" : "Run", systemImage: "play.fill", shortcut: "⌘↩", prominent: true) {
                    Task { await tab.runCurrent() }
                }
                ToolButton("Run All", systemImage: "forward.fill", shortcut: "⇧⌘↩") { Task { await tab.runAll() } }
            }
            ToolDivider()
            ToolButton("Explain", systemImage: "chart.bar.doc.horizontal", shortcut: "⌥⌘E") { tab.explainCurrent() }
            ToolButton("Format", systemImage: "text.alignleft", shortcut: "⌃I") { tab.format() }
            ToolButton("Save", systemImage: "star", shortcut: "⌥⌘S") { tab.saveAsFavorite() }
            if tab.inTransaction {
                ToolDivider()
                Tag("TRANSACTION OPEN", color: .systemOrange, systemImage: "arrow.triangle.2.circlepath")
                ToolButton("Commit", systemImage: "checkmark") { Task { await tab.commitTransaction() } }
                ToolButton("Rollback", systemImage: "arrow.uturn.backward") { Task { await tab.rollbackTransaction() } }
            }
        } trailing: {
            AIToggle(isOn: Binding(get: { workspace.isClaudeOpen }, set: { _ in workspace.toggleClaude() }))
        }
    }
}

/// "Ask Claude" switch in the query toolbar, tinted when the panel is open.
private struct AIToggle: View {
    @Binding var isOn: Bool
    @State private var hover = false

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "sparkles").font(.system(size: 11, weight: .medium))
                Text("Claude").lineLimit(1).fixedSize()
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isOn ? Color.white : Color.accentColor)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                .fill(isOn ? Color.accentColor : Color.accentColor.opacity(hover ? 0.16 : 0.10)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Claude assistant with your schema as context (⌘L)")
    }
}

/// Wraps SQLTextView; keeps the tab model and the text view in sync.
struct SQLEditorRepresentable: NSViewRepresentable {
    var tab: QueryTabModel
    var workspace: WorkspaceModel

    func makeNSView(context: Context) -> NSScrollView {
        let (scroll, tv) = SQLTextView.make()
        tv.indentWidth = AppSettings.indentWidth
        tv.setText(tab.sql)
        tv.setSelectedRange(NSRange(location: min(tab.selection.location, (tab.sql as NSString).length), length: 0))
        tv.onTextChange = { [weak tab] text in tab?.sql = text }
        tv.onSelectionChange = { [weak tab] r in tab?.selection = r }
        tv.completionEngine = { [weak workspace] in
            CompletionEngine(objects: workspace?.objects ?? [], columnsByTable: workspace?.columnsByTable ?? [:],
                             schemas: workspace?.schemas ?? [], favorites: FavoritesStore.shared.all(for: workspace?.connection.id),
                             uppercaseKeywords: UserDefaults.standard.bool(forKey: SettingKey.uppercaseCompletion))
        }
        tab.textView = tv
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? SQLTextView else { return }
        tab.textView = tv
        if tv.string != tab.sql { tv.setText(tab.sql) }
    }
}

struct ResultsPane: View {
    @Bindable var tab: QueryTabModel
    var workspace: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            if !tab.results.isEmpty {
                resultTabs
            }
            content
            if !(currentItem.map { tab.chartResults.contains($0.id) } ?? false) { statusBar }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var resultTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Space.xs) {
                ForEach(tab.results) { item in
                    let on = tab.selectedResultID == item.id || (tab.selectedResultID == nil && item.id == tab.results.last?.id)
                    Button { tab.selectedResultID = item.id } label: {
                        HStack(spacing: 5) {
                            Image(systemName: item.isError ? "xmark.octagon.fill" : "tablecells")
                                .font(.system(size: 10))
                                .foregroundStyle(item.isError ? Color.red : (on ? Color.accentColor : Color.secondary))
                            Text(item.title).lineLimit(1).fixedSize()
                        }
                        .font(.system(size: 11.5, weight: on ? .medium : .regular))
                        .foregroundStyle(on ? Color.primary : Color.secondary)
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                        .background(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).fill(on ? Color.primary.opacity(0.07) : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, DS.Space.m)
        }
        .overlay(alignment: .trailing) { viewModeSwitch.padding(.trailing, DS.Space.m) }
        .frame(height: 32)
        .background(DS.Palette.bar)
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { Divider() }
    }

    private var currentItem: QueryResultItem? {
        tab.results.first(where: { $0.id == tab.selectedResultID }) ?? tab.results.last
    }

    /// Table / Chart switch for row results (TablePlus has a "Chart" segment in the result pane).
    @ViewBuilder
    private var viewModeSwitch: some View {
        if let item = currentItem, case .rows(let r) = item.kind, !r.columns.isEmpty {
            CompactSegmented([(label: "Table", value: false), (label: "Chart", value: true)], selection: Binding(
                get: { tab.chartResults.contains(item.id) },
                set: { on in
                    if on {
                        tab.chartResults.insert(item.id)
                        if tab.chartConfigs[item.id] == nil { tab.chartConfigs[item.id] = ChartData.suggest(for: r) }
                    } else {
                        tab.chartResults.remove(item.id)
                    }
                }))
            .background(DS.Palette.bar)
            .help("Show this result as a table or a chart")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let item = currentItem {
            switch item.kind {
            case .rows(let r) where tab.chartResults.contains(item.id):
                ResultChartView(result: r, config: Binding(
                    get: { tab.chartConfigs[item.id] ?? ChartData.suggest(for: r) },
                    set: { tab.chartConfigs[item.id] = $0 }))
            case .rows(let r):
                ResultTableView(result: r)
            case .command(let r):
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.l) {
                        Banner(.success, r.summary)
                        ForEach(r.notices, id: \.self) { Banner(.info, $0) }
                        Text(item.statement).font(DS.Typo.monoSmall).foregroundStyle(.secondary).lineLimit(8).textSelection(.enabled)
                    }
                    .padding(DS.Space.xl)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .failure(let e):
                ErrorResultView(error: e, statement: item.statement, tab: tab, workspace: workspace)
            case .explain(let sql):
                ExplainPlanView(context: workspace, sql: sql)
            }
        } else {
            VStack(spacing: DS.Space.m) {
                Text("No results yet").font(DS.Typo.headline).foregroundStyle(.secondary)
                HStack(spacing: DS.Space.l) {
                    hint("Run", "⌘↩")
                    hint("Run all", "⇧⌘↩")
                    hint("Explain", "⌥⌘E")
                    hint("Claude", "⌘L")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) { Divider() }
        }
    }

    private func claudeItems(_ r: QueryResult, statement: String) -> [AskClaudeItem] {
        let sql = AIAttachments.sql(statement, title: "Query")
        let rows = AIAttachments.rows(title: "Result (\(r.rows.count) rows)", columns: r.columns, rows: r.rows)
        return [
            AskClaudeItem("Summarize This Result", systemImage: "text.alignleft") {
                AIRequest(title: "Summarize result", prompt: "Summarize what this result shows in a few sentences: headline numbers, trends, outliers.",
                          attachments: [sql, rows], focus: statement)
            },
            AskClaudeItem("Check the Result Looks Right", systemImage: "checkmark.seal") {
                AIRequest(title: "Check result", prompt: """
                    Does this result look correct for what the query seems to intend? Look for duplicated rows from joins, \
                    NULL handling, wrong grouping or time zones. Propose a fixed query in one ```sql block if needed.
                    """, attachments: [sql, rows], focus: statement)
            },
            AskClaudeItem("Explain the Query", systemImage: "text.magnifyingglass") {
                AIRequest(title: "Explain query", prompt: "Explain step by step what this query does and point out correctness or performance risks.",
                          attachments: [sql], focus: statement)
            },
            AskClaudeItem("Make It Faster", systemImage: "gauge.with.dots.needle.67percent") {
                AIRequest(title: "Optimize query", prompt: "Make this query faster without changing its result. Put index statements and the rewritten query in one ```sql block.",
                          attachments: [sql], focus: statement)
            },
        ]
    }

    private func hint(_ title: String, _ keys: String) -> some View {
        HStack(spacing: 5) {
            KeyCap(keys)
            Text(title).font(DS.Typo.caption).foregroundStyle(.secondary)
        }
    }

    private var statusBar: some View {
        StatusBar {
            if let item = tab.results.first(where: { $0.id == tab.selectedResultID }) ?? tab.results.last, case .rows(let r) = item.kind {
                Text(r.summary).monospacedDigit()
                if r.isTruncated {
                    Tag("LIMITED TO \(Fmt.count(Int64(AppSettings.queryRowLimit))) ROWS", color: .systemOrange)
                        .help("Change the limit in Settings")
                }
            } else {
                Text(tab.statusLine)
            }
        } trailing: {
            if let item = tab.results.first(where: { $0.id == tab.selectedResultID }) ?? tab.results.last, case .rows(let r) = item.kind {
                AskClaudeMenu(context: workspace, items: claudeItems(r, statement: item.statement))
                Menu {
                    ForEach(ExportFormat.allCases) { f in
                        Button("Copy as \(f.rawValue)") { Pasteboard.copy(DataExporter.render(r, format: f, tableName: nil, dialect: workspace.dialect)) }
                    }
                    Divider()
                    Button("Export…") { workspace.sheet = .export(.result(r, suggestedName: tab.title, tableName: nil)) }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }
}

struct ErrorResultView: View {
    var error: DatabaseError
    var statement: String
    var tab: QueryTabModel
    var workspace: WorkspaceModel
    @State private var fixing = false
    @State private var fixError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.m) {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    Text(error.message).font(.system(size: 13, weight: .semibold)).textSelection(.enabled)
                    Spacer(minLength: 0)
                    if let s = error.sqlState { Tag("SQLSTATE \(s)", color: .systemGray, style: .outline) }
                }
                if error.detail != nil || error.hint != nil {
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        if let d = error.detail { labeled("Detail", d) }
                        if let h = error.hint { labeled("Hint", h) }
                    }
                }
                HStack(spacing: DS.Space.m) {
                    Button {
                        fixing = true
                        fixError = nil
                        Task {
                            do {
                                let fixed = try await AIService.fix(sql: statement, error: error.fullMessage, context: workspace)
                                tab.insertSQL(fixed, replaceAll: false)
                            } catch {
                                fixError = error.localizedDescription
                            }
                            fixing = false
                        }
                    } label: {
                        Label("Fix with Claude", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.accentColor)
                    .disabled(fixing)
                    Button("Copy Error") { Pasteboard.copy(error.fullMessage) }
                    if fixing { ProgressView().controlSize(.small) }
                }
                .controlSize(.small)
                if let fixError { Banner(.error, fixError) }
            }
            .padding(DS.Space.l)
            .background(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous).fill(Color.red.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous).strokeBorder(Color.red.opacity(0.18), lineWidth: 0.5))
            .padding(DS.Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func labeled(_ title: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.m) {
            Text(title.uppercased()).font(DS.Typo.eyebrow).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
            Text(text).font(DS.Typo.callout).textSelection(.enabled)
        }
    }
}
