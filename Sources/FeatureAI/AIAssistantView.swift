import AppKit
import MTPCore
import MTPUIKit
import SwiftUI

struct AIChatMessage: Identifiable {
    enum Role { case user, assistant, error }

    let id = UUID()
    var role: Role
    var title: String?
    var text: String
    var segments: [AIMarkdown.Segment]
    var footnote: String?
    /// Context sent with a user message (titles shown as chips).
    var attachments: [AIAttachment] = []
}

/// The workspace's Claude conversation. One per window, shared by every screen: Insights, table data,
/// structure and query tabs all send their questions here with their own context attached.
@MainActor
public final class AIAssistantModel: ObservableObject {
    @Published var messages: [AIChatMessage] = []
    @Published var input = ""
    @Published var isRunning = false
    @Published var model: String = AISettings.defaultModel
    /// Context waiting to be sent with the next message (from `ask(_:)` with `autoSend: false`).
    @Published var pendingAttachments: [AIAttachment] = []
    @Published var pendingTitle: String?
    /// Bumped when a screen asks for the composer to get focus.
    @Published var focusRequest = 0

    let context: WorkspaceContext
    /// The query editor of the current tab, when there is one (Insert / Replace / Fix use it).
    public weak var bridge: AIEditorBridge?
    private var task: Task<Void, Never>?
    private var pendingFocus = ""

    public init(context: WorkspaceContext, bridge: AIEditorBridge? = nil) {
        self.context = context
        self.bridge = bridge
    }

    private var editorSQL: String {
        let selected = bridge?.selectedSQL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return selected.isEmpty ? (bridge?.editorSQL ?? "") : selected
    }

    var hasSQL: Bool { !editorSQL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var canFix: Bool { bridge?.lastError?.isEmpty == false && hasSQL }
    var canSend: Bool { !isRunning && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var hasEditor: Bool { bridge != nil }

    /// What Claude can use for this connection (shown in the panel header).
    var access: ClaudeCLI.Access { AIService.access(for: context.connection) }

    /// Entry point for every screen: sends right away, or pre-fills the composer with the context attached.
    public func ask(_ request: AIRequest) {
        let attachments = filtered(request.attachments)
        if request.autoSend, !request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            start(.custom(title: request.title, prompt: request.prompt, attachments: attachments, focus: request.focus),
                  shown: [.text(request.prompt)], attachments: attachments)
        } else {
            pendingAttachments = attachments
            pendingTitle = request.title
            pendingFocus = request.focus
            if !request.prompt.isEmpty { input = request.prompt }
            focusRequest += 1
        }
    }

    /// Rows only leave the Mac when the connection lets Claude read data; otherwise they are dropped, with a note.
    private func filtered(_ attachments: [AIAttachment]) -> [AIAttachment] {
        guard !context.connection.effectiveClaudeCanQuery else { return attachments }
        let dropped = attachments.filter(\.containsRowData)
        if !dropped.isEmpty {
            let note = "Not sent: \(dropped.map(\.title).joined(separator: ", ")) (row data). Allow \"Claude can read data\" in this connection's settings to include rows."
            messages.append(AIChatMessage(role: .error, text: note, segments: [.text(note)]))
        }
        return attachments.filter { !$0.containsRowData }
    }

    func send() {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        input = ""
        if !pendingAttachments.isEmpty || bridge == nil {
            let attachments = pendingAttachments
            let title = pendingTitle ?? "Question"
            pendingAttachments = []
            pendingTitle = nil
            start(.custom(title: title, prompt: q, attachments: attachments, focus: pendingFocus), shown: [.text(q)], attachments: attachments)
        } else {
            start(.generate(question: q, currentSQL: bridge?.editorSQL), shown: [.text(q)])
        }
    }

    func removePending(_ a: AIAttachment) { pendingAttachments.removeAll { $0.id == a.id } }

    func explain() { start(.explain(sql: editorSQL), shown: [.code(language: "sql", code: editorSQL)]) }

    func optimize() { start(.optimize(sql: editorSQL, plan: nil), shown: [.code(language: "sql", code: editorSQL)]) }

    func fix() {
        guard let error = bridge?.lastError else { return }
        start(.fix(sql: editorSQL, error: error), shown: [.code(language: "sql", code: editorSQL), .text(error)])
    }

    private var history: [AIChatTurn] {
        messages.compactMap { m in
            switch m.role {
            case .user: return AIChatTurn(isUser: true, text: [m.title, m.text.isEmpty ? m.segments.plainText : m.text].compactMap { $0 }.joined(separator: ": "))
            case .assistant: return AIChatTurn(isUser: false, text: m.text)
            case .error: return nil
            }
        }
    }

    private func start(_ aiTask: AITask, shown: [AIMarkdown.Segment], attachments: [AIAttachment] = []) {
        guard !isRunning else { return }
        let history = history
        messages.append(AIChatMessage(role: .user, title: aiTask.title, text: "", segments: shown, attachments: attachments))
        isRunning = true
        let model = model
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let answer = try await AIService.ask(aiTask, context: self.context, model: model, history: history)
                var foot = answer.model ?? model
                if let ms = answer.durationMS { foot += " · " + Fmt.duration(Double(ms) / 1000) }
                self.messages.append(AIChatMessage(role: .assistant, text: answer.text, segments: AIMarkdown.segments(answer.text), footnote: foot))
            } catch {
                let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.messages.append(AIChatMessage(role: .error, text: text, segments: [.text(text)]))
            }
            self.isRunning = false
            self.task = nil
        }
    }

    func cancel() { task?.cancel() }

    func clear() {
        cancel()
        messages.removeAll()
        pendingAttachments = []
        pendingTitle = nil
    }

    func insert(_ sql: String, replace: Bool) {
        if let bridge { bridge.insertSQL(sql, replaceAll: replace) } else { openInNewTab(sql) }
    }

    func openInNewTab(_ sql: String) { context.openQueryTab(title: "Claude", sql: sql, run: false) }
}

extension Array where Element == AIMarkdown.Segment {
    var plainText: String {
        map { seg in
            switch seg {
            case .text(let t): return t
            case .code(_, let c): return c
            }
        }.joined(separator: "\n")
    }
}

/// Side panel: ask in natural language, get SQL with schema context; explain / optimise / fix.
public struct AIAssistantView: View {
    @StateObject private var model: AIAssistantModel
    @FocusState private var inputFocused: Bool

    public init(context: WorkspaceContext, bridge: AIEditorBridge?) {
        _model = StateObject(wrappedValue: AIAssistantModel(context: context, bridge: bridge))
    }

    /// The workspace's shared conversation (the app keeps one per window).
    public init(model: AIAssistantModel) {
        _model = StateObject(wrappedValue: model)
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            transcript
            composer
        }
        .frame(minWidth: 280)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: DS.Radius.s + 1, style: .continuous).fill(Color.accentColor.opacity(0.12)))
            Text("Claude").font(DS.Typo.headline).lineLimit(1)
            Spacer(minLength: DS.Space.s)
            accessBadges
            AIIconButton(systemImage: "trash", help: "Clear conversation") { model.clear() }
                .disabled(model.messages.isEmpty)
        }
        .padding(.leading, DS.Space.l)
        .padding(.trailing, DS.Space.s)
        .frame(height: DS.Metrics.toolbarHeight)
        .background(DS.Palette.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// What Claude can use on this connection, so it's never a surprise.
    private var accessBadges: some View {
        let access = model.access
        return HStack(spacing: 4) {
            if let repo = access.codeRepository {
                Tag("CODE", color: .systemPurple, systemImage: "folder")
                    .help("Claude can read \(repo.path) (read-only)")
            }
            if access.databaseTools != nil {
                Tag("QUERIES", color: .systemGreen, systemImage: "cylinder")
                    .help("Claude can run read-only queries on this connection and read the rows")
            } else {
                Tag("SCHEMA ONLY", color: .systemGray, style: .outline)
                    .help("Claude sees the schema, not the data. Change it in the connection settings.")
            }
        }
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Space.l) {
                    ForEach(model.messages) { m in
                        MessageView(message: m, canInsert: model.hasEditor,
                                    insert: { model.insert($0, replace: false) },
                                    replace: { model.insert($0, replace: true) },
                                    openTab: { model.openInNewTab($0) })
                        .id(m.id)
                    }
                    if model.isRunning {
                        HStack(spacing: DS.Space.m) {
                            ProgressView().controlSize(.small)
                            Text("Thinking…").font(DS.Typo.callout).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, DS.Space.xs)
                        .id("spinner")
                    }
                }
                .padding(DS.Space.l)
            }
            .overlay {
                if model.messages.isEmpty && !model.isRunning { emptyState }
            }
            .onChange(of: model.messages.count) {
                if let last = model.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .top) } }
            }
            .onChange(of: model.isRunning) {
                if model.isRunning { withAnimation { proxy.scrollTo("spinner", anchor: .bottom) } }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: DS.Space.l) {
            Image(systemName: "sparkles")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous).fill(Color.accentColor.opacity(0.10)))
            VStack(spacing: DS.Space.xs) {
                Text("Ask Claude about your data").font(DS.Typo.headline)
                Text(model.hasEditor ? "Describe the query you need, or use the actions below on the SQL in the editor."
                     : "Ask about this database, or use ✦ Ask Claude on Insights, table data and structure.")
                    .font(DS.Typo.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: DS.Space.s) {
                hint("tablecells", "Answers use the current schema")
                if model.access.codeRepository != nil { hint("folder", "Reads your code repository") }
                hint(model.access.databaseTools != nil ? "cylinder" : "eye.slash",
                     model.access.databaseTools != nil ? "Can run read-only queries" : "Never sees your rows")
                hint("hand.raised", "Never modifies your data")
            }
            .padding(.top, DS.Space.xs)
        }
        .frame(maxWidth: 260)
        .padding(DS.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func hint(_ icon: String, _ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: icon).frame(width: 16)
        }
        .font(DS.Typo.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: Composer

    private func chips(icons: Bool) -> some View {
        HStack(spacing: DS.Space.s) {
            SuggestionChip("Explain", systemImage: icons ? "text.magnifyingglass" : nil) { model.explain() }
                .disabled(model.isRunning || !model.hasSQL)
                .help("Explain the SQL in the editor (or the selection)")
            SuggestionChip("Optimize", systemImage: icons ? "gauge.with.dots.needle.67percent" : nil) { model.optimize() }
                .disabled(model.isRunning || !model.hasSQL)
                .help("Suggest a faster version of the SQL in the editor")
            SuggestionChip("Fix error", systemImage: icons ? "wrench.and.screwdriver" : nil) { model.fix() }
                .disabled(model.isRunning || !model.canFix)
                .help("Fix the last error of the editor query")
        }
        .fixedSize()
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            if model.hasEditor {
                ViewThatFits(in: .horizontal) {
                    chips(icons: true)
                    chips(icons: false)
                }
            }
            if !model.pendingAttachments.isEmpty {
                pendingChips
            }
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $model.input)
                        .font(DS.Typo.body)
                        .focused($inputFocused)
                        .frame(height: 56)
                        .scrollContentBackground(.hidden)
                    if model.input.isEmpty {
                        Text(model.pendingAttachments.isEmpty ? (model.hasEditor ? "Describe the query you need…" : "Ask about this database…")
                             : "Ask about the attached context…")
                            .font(DS.Typo.body)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, DS.Space.s)
                .padding(.top, DS.Space.s)
                HStack(spacing: DS.Space.s) {
                    ModelMenu(selection: $model.model)
                    Spacer(minLength: DS.Space.xs)
                    KeyCap("⌘↩")
                    if model.isRunning {
                        Button { model.cancel() } label: { Image(systemName: "stop.fill") }
                            .buttonStyle(SendButtonStyle(stop: true))
                            .help("Stop")
                    } else {
                        Button { model.send() } label: { Image(systemName: "arrow.up") }
                            .buttonStyle(SendButtonStyle(stop: false))
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(!model.canSend)
                            .help(model.hasEditor && model.pendingAttachments.isEmpty ? "Write SQL (⌘↩)" : "Send (⌘↩)")
                    }
                }
                .padding(.horizontal, DS.Space.s)
                .padding(.bottom, DS.Space.s)
                .padding(.top, DS.Space.xxs)
            }
            .background(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
                .strokeBorder(inputFocused ? Color.accentColor.opacity(0.6) : DS.Palette.separator, lineWidth: inputFocused ? 1 : 0.5))
            .contentShape(Rectangle())
            .onTapGesture { inputFocused = true }
            Text("Claude can make mistakes. Review SQL before running it.")
                .font(DS.Typo.micro)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.top, DS.Space.l)
        .padding(.bottom, DS.Space.m)
        .background(DS.Palette.bar)
        .overlay(alignment: .top) { Divider() }
        .onAppear { inputFocused = true }
        .onChange(of: model.focusRequest) { inputFocused = true }
    }

    private var pendingChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Space.xs) {
                ForEach(model.pendingAttachments) { a in
                    HStack(spacing: 4) {
                        Image(systemName: a.systemImage).font(.system(size: 9.5))
                        Text(a.title).lineLimit(1)
                        Button { model.removePending(a) } label: { Image(systemName: "xmark").font(.system(size: 7.5, weight: .bold)) }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help("Don't send this")
                    }
                    .font(.system(size: 11))
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(Capsule().fill(Color.accentColor.opacity(0.10)))
                    .help(String(a.content.prefix(400)))
                }
            }
        }
    }
}

// MARK: - Pieces

/// Model selector rendered as a quiet text menu ("Sonnet ⌄") instead of a stock popup.
private struct ModelMenu: View {
    @Binding var selection: String
    @State private var hover = false

    var body: some View {
        Menu {
            ForEach(ClaudeCLI.modelAliases, id: \.self) { alias in
                Button {
                    selection = alias
                } label: {
                    if alias == selection { Label(alias.capitalized, systemImage: "checkmark") } else { Text(alias.capitalized) }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(selection.capitalized).font(.system(size: 11.5, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).fill(hover ? DS.Palette.pressed : DS.Palette.hover))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hover = $0 }
        .help("Model")
    }
}

/// Square icon-only button with a hover fill (header and code action bars).
struct AIIconButton: View {
    var systemImage: String
    var help: String
    var size: CGFloat = 24
    var action: () -> Void
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size > 22 ? 11.5 : 10.5, weight: .medium))
                .foregroundStyle(enabled ? Color.primary.opacity(0.75) : Color(nsColor: .tertiaryLabelColor))
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: DS.Radius.s + 1, style: .continuous).fill(hover && enabled ? DS.Palette.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// Rounded action chip under the transcript ("Explain", "Optimize", "Fix error").
struct SuggestionChip: View {
    var title: String
    var systemImage: String?
    var action: () -> Void
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    init(_ title: String, systemImage: String?, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 10, weight: .medium)) }
                Text(title).lineLimit(1).fixedSize()
            }
            .font(.system(size: 11.5))
            .foregroundStyle(enabled ? Color.primary.opacity(0.85) : Color(nsColor: .tertiaryLabelColor))
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Capsule().fill(hover && enabled ? DS.Palette.pressed : DS.Palette.surface))
            .overlay(Capsule().strokeBorder(DS.Palette.separator, lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Round send / stop button inside the composer box.
private struct SendButtonStyle: ButtonStyle {
    var stop: Bool
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: stop ? 9 : 11.5, weight: .bold))
            .foregroundStyle(enabled ? Color.white : Color(nsColor: .tertiaryLabelColor))
            .frame(width: 24, height: 24)
            .background(Circle().fill(fill(configuration.isPressed)))
            .contentShape(Circle())
    }

    private func fill(_ pressed: Bool) -> Color {
        guard enabled else { return Color.primary.opacity(0.08) }
        return (stop ? Color.primary.opacity(0.7) : Color.accentColor).opacity(pressed ? 0.8 : 1)
    }
}

private struct MessageView: View {
    let message: AIChatMessage
    let canInsert: Bool
    let insert: (String) -> Void
    let replace: (String) -> Void
    let openTab: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            if message.role == .assistant {
                // Replies read as plain text, no bubble.
                segments
                    .padding(.horizontal, DS.Space.xxs)
                if let f = message.footnote {
                    HStack(spacing: DS.Space.xs) {
                        Image(systemName: "sparkles").font(.system(size: 8, weight: .semibold)).foregroundStyle(Color.accentColor)
                        Text(f).monospacedDigit()
                    }
                    .font(DS.Typo.micro)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, DS.Space.xxs)
                    .padding(.top, DS.Space.xxs)
                }
            } else {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    if message.role == .error || message.title != nil {
                        HStack(spacing: 5) {
                            roleIcon
                            Text(message.title ?? "Error")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    segments
                    if !message.attachments.isEmpty {
                        HStack(spacing: DS.Space.xs) {
                            ForEach(message.attachments) { a in
                                Label(a.title, systemImage: a.systemImage)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .frame(height: 18)
                                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                                    .help(String(a.content.prefix(400)))
                            }
                        }
                    }
                }
                .padding(DS.Space.m + DS.Space.xxs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous).fill(background))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous).strokeBorder(border, lineWidth: 0.5))
            }
        }
    }

    private var segments: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            ForEach(Array(message.segments.enumerated()), id: \.offset) { _, seg in
                switch seg {
                case .text(let t):
                    Text((try? AttributedString(markdown: t, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(t))
                        .font(DS.Typo.body)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .code(let language, let code):
                    codeBlock(code, language: language)
                }
            }
        }
    }

    @ViewBuilder
    private var roleIcon: some View {
        switch message.role {
        case .user:
            Image(systemName: "person.crop.circle.fill").font(.system(size: 11)).foregroundStyle(.secondary)
        case .assistant:
            Image(systemName: "sparkles").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.accentColor)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(.orange)
        }
    }

    private var background: Color {
        switch message.role {
        case .user: return Color.primary.opacity(0.045)
        case .assistant: return DS.Palette.surface
        case .error: return Color.orange.opacity(0.10)
        }
    }

    private var border: Color {
        switch message.role {
        case .user: return DS.Palette.separator.opacity(0.6)
        case .assistant: return DS.Palette.separator.opacity(0.7)
        case .error: return Color.orange.opacity(0.3)
        }
    }

    private func codeBlock(_ code: String, language: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                Text((language.isEmpty ? "code" : language).uppercased())
                    .font(DS.Typo.eyebrow).tracking(0.6).foregroundStyle(.secondary)
                Spacer(minLength: DS.Space.s)
                if message.role == .assistant {
                    AIIconButton(systemImage: "text.insert", help: "Insert at cursor", size: 20) { insert(code) }.disabled(!canInsert)
                    AIIconButton(systemImage: "arrow.left.arrow.right", help: "Replace editor contents", size: 20) { replace(code) }.disabled(!canInsert)
                    AIIconButton(systemImage: "plus.rectangle.on.rectangle", help: "Open in new tab", size: 20) { openTab(code) }
                    AIIconButton(systemImage: "doc.on.doc", help: "Copy", size: 20) { Pasteboard.copy(code) }
                }
            }
            .padding(.leading, DS.Space.m)
            .padding(.trailing, DS.Space.xxs)
            .frame(height: 26)
            .background(Color.primary.opacity(0.035))
            .overlay(alignment: .bottom) { Rectangle().fill(DS.Palette.separator.opacity(0.7)).frame(height: 0.5) }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(DS.Typo.mono)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(DS.Space.m)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).strokeBorder(DS.Palette.separator, lineWidth: 0.5))
    }
}
