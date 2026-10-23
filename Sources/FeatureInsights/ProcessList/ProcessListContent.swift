import MTPCore
import MTPUIKit
import SwiftUI

extension PGProcess {
    var sortClient: String { clientAddress.isEmpty ? (clientHostname ?? "") : clientAddress }
    var sortWait: String { waitDescription }
}

struct ProcessListContent: View {
    @ObservedObject var model: ProcessListModel

    var body: some View {
        VStack(spacing: 0) {
            ProcessListToolbar(model: model)
            if let error = model.error {
                SectionErrorView(message: error)
                    .padding(.horizontal, DS.Space.l)
                    .padding(.vertical, DS.Space.m)
            }
            VSplitView {
                ProcessTable(model: model)
                    .frame(minHeight: 160)
                ProcessDetail(model: model)
                    .frame(minHeight: 150, idealHeight: 220)
            }
            StatusBar {
                Text(countText).monospacedDigit()
            } trailing: {
                if let last = model.lastRefresh {
                    Text("Updated \(last.formatted(date: .omitted, time: .standard))").monospacedDigit()
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    var countText: String {
        let shown = model.visible.count
        let total = model.processes.count
        let active = model.processes.filter(\.isActive).count
        return "\(shown) shown · \(active) active · \(total) total"
    }
}

/// Process name and connection live in the tab and window toolbar: the strip holds only filters and refresh.
struct ProcessListToolbar: View {
    @ObservedObject var model: ProcessListModel

    var body: some View {
        ToolStrip {
            FilterField(text: $model.filter, prompt: "Filter pid, user, app, query")
                .frame(minWidth: 140, idealWidth: 240, maxWidth: 260)
                .padding(.trailing, DS.Space.xs)
            ToolDivider()
            ToggleChip(title: "Idle", systemImage: "moon.zzz", isOn: $model.showIdle, help: "Show idle sessions")
            ToggleChip(title: "Own", systemImage: "person.crop.circle", isOn: $model.showOwn, help: "Show the connection used by this list")
            ToggleChip(title: "System", systemImage: "gearshape.2", isOn: $model.showSystem,
                       help: "Show background processes (checkpointer, WAL writer…)")
        } trailing: {
            AskClaudeMenu(context: model.context, items: [
                AskClaudeItem("Explain What's Running", systemImage: "list.bullet.rectangle") {
                    AIRequest(title: "Sessions", prompt: """
                        Explain these sessions: who is blocking whom, long or idle-in-transaction sessions, and what to do \
                        (which pid to cancel or terminate, and why). Be careful: this may be production.
                        """, attachments: [model.sessionsForClaude()])
                },
            ])
            if model.isLoading { ProgressView().controlSize(.mini).padding(.trailing, DS.Space.xs) }
            ToggleChip(title: "Auto-refresh", systemImage: "timer", isOn: $model.autoRefresh, help: "Refresh every 2 seconds")
            ToolButton("Refresh", systemImage: "arrow.clockwise") {
                Task { await model.refresh() }
            }
        }
    }
}

/// Compact search field sized for a `ToolStrip` row.
struct FilterField: View {
    @Binding var text: String
    var prompt: String

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain).font(DS.Typo.callout)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
                    .help("Clear filter")
            }
        }
        .padding(.horizontal, DS.Space.s + 1)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).strokeBorder(DS.Palette.separator.opacity(0.7), lineWidth: 0.5))
    }
}

struct ProcessTable: View {
    @ObservedObject var model: ProcessListModel

    var body: some View {
        Table(model.visible, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("PID", value: \PGProcess.pid) { (p: PGProcess) in
                HStack(spacing: 4) {
                    Text(String(p.pid)).monospacedDigit()
                    if !p.blockedBy.isEmpty {
                        Image(systemName: "lock.fill").foregroundStyle(.red).help("Blocked by \(p.blockedBy.map(String.init).joined(separator: ", "))")
                    }
                }
            }
            .width(min: 55, ideal: 70)
            TableColumn("User", value: \PGProcess.user) { (p: PGProcess) in
                Text(p.user.isEmpty ? p.backendType : p.user).foregroundStyle(p.user.isEmpty ? Color.secondary : Color.primary)
            }
            .width(min: 60, ideal: 90)
            TableColumn("Application", value: \PGProcess.application) { (p: PGProcess) in
                Text(p.application).lineLimit(1)
            }
            .width(min: 70, ideal: 130)
            TableColumn("Client", value: \PGProcess.sortClient) { (p: PGProcess) in
                Text(p.sortClient.isEmpty ? (p.backendType == "client backend" ? "local socket" : "") : p.sortClient)
                    .foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 70, ideal: 110)
            TableColumn("Database", value: \PGProcess.database) { (p: PGProcess) in
                Text(p.database).lineLimit(1)
            }
            .width(min: 50, ideal: 70)
            TableColumn("State", value: \PGProcess.state) { (p: PGProcess) in
                StateLabel(process: p)
            }
            .width(min: 70, ideal: 120)
            TableColumn("Wait", value: \PGProcess.sortWait) { (p: PGProcess) in
                Text(p.waitDescription).foregroundStyle(p.waitEventType == "Lock" ? Color.red : Color.secondary).lineLimit(1)
            }
            .width(min: 60, ideal: 120)
            TableColumn("Duration", value: \PGProcess.duration) { (p: PGProcess) in
                Text(InsightsFormat.duration(p.duration))
                    .monospacedDigit()
                    .foregroundStyle(durationColor(p))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 75)
            TableColumn("Query", value: \PGProcess.query) { (p: PGProcess) in
                Text(p.queryPreview).font(DS.Typo.mono).lineLimit(1)
            }
            .width(min: 200, ideal: 480)
        }
        .contextMenu(forSelectionType: PGProcess.ID.self) { ids in
            if let pid = ids.first, let p = model.processes.first(where: { $0.pid == pid }) {
                Button("Cancel Query…") { Task { await model.send(.cancel, to: p) } }.disabled(p.isSelf)
                Button("Terminate Process…") { Task { await model.send(.terminate, to: p) } }.disabled(p.isSelf)
                Divider()
                Button("Copy Query") { Pasteboard.copy(p.query) }
                Button("Copy PID") { Pasteboard.copy(String(p.pid)) }
                Button("Open Query in Query Tab") { model.context.openQueryTab(title: "Process \(p.pid)", sql: p.query, run: false) }
                    .disabled(p.query.isEmpty)
            }
        }
    }

    func durationColor(_ p: PGProcess) -> Color {
        guard p.isActive || p.isIdleInTransaction else { return .secondary }
        if p.duration > 300 { return .red }
        if p.duration > 30 { return .orange }
        return .primary
    }
}

struct StateLabel: View {
    var process: PGProcess

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(process.state.isEmpty ? "—" : process.state).lineLimit(1)
        }
    }

    var color: Color {
        if process.isActive { return process.waitEventType == "Lock" ? .red : .green }
        if process.isIdleInTransaction { return .orange }
        return .secondary.opacity(0.5)
    }
}

struct ProcessDetail: View {
    @ObservedObject var model: ProcessListModel

    var body: some View {
        if let p = model.selected {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                HStack(spacing: DS.Space.m) {
                    Text("Process \(p.pid)").font(DS.Typo.headline).monospacedDigit()
                    StateLabel(process: p).font(DS.Typo.callout).foregroundStyle(.secondary)
                    if p.isSelf { Tag("this list's connection", tone: .info) }
                    if p.application.hasPrefix("TableExtra") { Tag("TableExtra", tone: .info) }
                    Spacer(minLength: DS.Space.m)
                    ToolButton("Copy Query", systemImage: "doc.on.doc") { Pasteboard.copy(p.query) }
                        .disabled(p.query.isEmpty)
                    ToolButton("Open in Query Tab", systemImage: "arrow.up.forward.square") {
                        model.context.openQueryTab(title: "Process \(p.pid)", sql: p.query, run: false)
                    }
                    .disabled(p.query.isEmpty)
                    ToolDivider()
                    ToolButton("Cancel Query", systemImage: "stop.circle",
                               help: "pg_cancel_backend: stops the running statement, keeps the session") { Task { await model.send(.cancel, to: p) } }
                        .disabled(p.isSelf || !p.isActive)
                    ToolButton("Terminate", systemImage: "xmark.octagon", role: .destructive,
                               help: "pg_terminate_backend: closes the session and rolls back its transaction") { Task { await model.send(.terminate, to: p) } }
                        .disabled(p.isSelf)
                }
                .frame(height: 26)
                facts(p)
                CodeView(p.query.isEmpty ? "-- no query" : p.query)
                    .frame(minHeight: 60)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).strokeBorder(DS.Palette.separator, lineWidth: 0.5))
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, DS.Space.m + 2)
        } else {
            EmptyState("No process selected", systemImage: "list.bullet.rectangle",
                       message: model.visible.isEmpty ? "No session matches the filters. Turn on Idle or System to see more." : "Select a process to see its full query.")
        }
    }

    func facts(_ p: PGProcess) -> some View {
        let items: [(String, String)] = [
            ("User", p.user.isEmpty ? "—" : p.user),
            ("Database", p.database.isEmpty ? "—" : p.database),
            ("Client", [p.sortClient, p.clientPort.map { ":\($0)" } ?? ""].joined()),
            ("Backend", p.backendType),
            ("Connected", InsightsFormat.duration(p.backendSeconds)),
            ("Transaction", p.transactionSeconds.map { InsightsFormat.duration($0) } ?? "none"),
            ("Query running", p.isActive ? InsightsFormat.duration(p.querySeconds) : "—"),
            ("In state", InsightsFormat.duration(p.stateSeconds)),
            ("Wait", p.waitDescription.isEmpty ? "—" : p.waitDescription),
            ("Blocked by", p.blockedBy.isEmpty ? "—" : p.blockedBy.map(String.init).joined(separator: ", ")),
            ("xmin", p.backendXmin ?? "—"),
        ]
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: DS.Space.l, alignment: .leading)], alignment: .leading, spacing: DS.Space.xs) {
            ForEach(items, id: \.0) { item in
                HStack(spacing: DS.Space.s) {
                    Text(item.0).foregroundStyle(.secondary).frame(width: 78, alignment: .leading)
                    Text(item.1).lineLimit(1).truncationMode(.middle).monospacedDigit().textSelection(.enabled)
                }
                .font(DS.Typo.caption)
            }
        }
    }
}

/// Shown instead of the process list for SQLite.
struct NotSupportedView: View {
    var title: String
    var message: String

    var body: some View {
        EmptyState(title, systemImage: "nosign", message: message)
    }
}
