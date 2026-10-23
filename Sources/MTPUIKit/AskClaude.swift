import AppKit
import MTPCore
import SwiftUI

/// Context a screen hands to Claude with a question: a table definition, an insights report, selected rows…
public struct AIAttachment: Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var title: String
    public var systemImage: String
    public var content: String
    /// True when `content` holds row values (not just schema). Sent only when the connection allows Claude
    /// to read data; otherwise it is dropped and the conversation says so.
    public var containsRowData: Bool

    public init(title: String, systemImage: String = "paperclip", content: String, containsRowData: Bool = false) {
        self.title = title
        self.systemImage = systemImage
        self.content = content
        self.containsRowData = containsRowData
    }
}

/// A question to Claude, asked from anywhere in the workspace.
public struct AIRequest: Sendable {
    /// Short label shown in the conversation ("Explain orders").
    public var title: String
    public var prompt: String
    public var attachments: [AIAttachment]
    /// Table names, SQL… used to pick the most relevant schema to send.
    public var focus: String
    /// Send right away (true) or put the prompt in the composer for editing (false).
    public var autoSend: Bool

    public init(title: String, prompt: String, attachments: [AIAttachment] = [], focus: String = "", autoSend: Bool = true) {
        self.title = title
        self.prompt = prompt
        self.attachments = attachments
        self.focus = focus
        self.autoSend = autoSend
    }
}

/// One entry of an "Ask Claude" menu.
public struct AskClaudeItem: Identifiable {
    public var id = UUID()
    public var title: String
    public var systemImage: String
    public var request: () -> AIRequest
    public var disabledReason: String?

    public init(_ title: String, systemImage: String, disabledReason: String? = nil, request: @escaping () -> AIRequest) {
        self.title = title
        self.systemImage = systemImage
        self.request = request
        self.disabledReason = disabledReason
    }
}

/// "✦ Claude" menu button placed in screen toolbars. Each item opens the assistant with that screen's context.
public struct AskClaudeMenu: View {
    var context: WorkspaceContext
    var title: String
    var items: [AskClaudeItem]
    @Environment(\.toolStripCompact) private var compact
    @State private var hover = false

    public init(context: WorkspaceContext, title: String = "Ask Claude", items: [AskClaudeItem]) {
        self.context = context
        self.title = title
        self.items = items
    }

    public var body: some View {
        Menu {
            ForEach(items) { item in
                Button { context.askClaude(item.request()) } label: { Label(item.title, systemImage: item.systemImage) }
                    .disabled(item.disabledReason != nil)
                    .help(item.disabledReason ?? "")
            }
            Divider()
            Button { context.askClaude(AIRequest(title: "Question", prompt: "", autoSend: false)) } label: {
                Label("Ask Something Else…", systemImage: "text.bubble")
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "sparkles").font(.system(size: 11, weight: .medium))
                if !compact { Text(title).lineLimit(1).fixedSize() }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, compact ? 6 : 9)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).fill(Color.accentColor.opacity(hover ? 0.16 : 0.10)))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hover = $0 }
        .help("Ask Claude about this screen")
    }
}

/// Small inline "✦" button for one finding / row / plan node.
public struct AskClaudeInlineButton: View {
    var context: WorkspaceContext
    var help: String
    var request: () -> AIRequest
    @State private var hover = false

    public init(context: WorkspaceContext, help: String = "Ask Claude", request: @escaping () -> AIRequest) {
        self.context = context
        self.help = help
        self.request = request
    }

    public var body: some View {
        Button { context.askClaude(request()) } label: {
            Image(systemName: "sparkles").font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22, height: 20)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.accentColor.opacity(hover ? 0.16 : 0.08)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// Plain-text renderers for common attachments.
public enum AIAttachments {
    /// CREATE TABLE-like summary: columns, keys, indexes, constraints, triggers.
    public static func table(_ d: TableDetails, dialect: SQLDialect) -> AIAttachment {
        AIAttachment(title: d.object.qualifiedName, systemImage: "tablecells", content: DDLWriter.createTable(d, dialect: dialect, includeIndexes: false) + indexes(d))
    }

    private static func indexes(_ d: TableDetails) -> String {
        guard !d.indexes.isEmpty else { return "" }
        return "\n\n-- indexes\n" + d.indexes.map { i in
            var line = i.definition.isEmpty ? "\(i.name) (\(i.columns.joined(separator: ", ")))" : i.definition
            if let scans = i.scans { line += "  -- \(scans) scans" }
            if let size = i.sizeBytes { line += ", \(Fmt.bytes(size))" }
            return line
        }.joined(separator: "\n")
    }

    /// Rows as a compact TSV with a header (values truncated), for questions about data.
    public static func rows(title: String, columns: [ResultColumn], rows: [[String?]], limit: Int = 50) -> AIAttachment {
        var out = columns.map { "\($0.name) (\($0.typeName))" }.joined(separator: "\t") + "\n"
        for row in rows.prefix(limit) {
            out += row.map { v in
                guard let v else { return "NULL" }
                let s = v.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
                return s.count > 120 ? String(s.prefix(120)) + "…" : s
            }.joined(separator: "\t") + "\n"
        }
        if rows.count > limit { out += "… \(rows.count - limit) more rows not shown\n" }
        return AIAttachment(title: title, systemImage: "tablecells.badge.ellipsis", content: out, containsRowData: true)
    }

    public static func sql(_ sql: String, title: String = "SQL") -> AIAttachment {
        AIAttachment(title: title, systemImage: "chevron.left.forwardslash.chevron.right", content: sql)
    }

    public static func text(_ text: String, title: String, systemImage: String = "doc.text", containsRowData: Bool = false) -> AIAttachment {
        AIAttachment(title: title, systemImage: systemImage, content: text, containsRowData: containsRowData)
    }
}
