import MTPCore
import MTPUIKit
import SwiftUI

// Public entry points used by the app. Keep these signatures stable.
// Views: AIAssistantView.swift, AISettingsView.swift, MCPSettingsView.swift.

/// Implemented by the query editor so the assistant can read and write SQL.
@MainActor
public protocol AIEditorBridge: AnyObject {
    var editorSQL: String { get }
    var selectedSQL: String? { get }
    var lastError: String? { get }
    func insertSQL(_ sql: String, replaceAll: Bool)
}

/// Claude (through the local `claude` CLI) with schema context. Never executes SQL.
public enum AIService {
    /// Suggests a corrected statement for a failed query.
    @MainActor
    public static func fix(sql: String, error: String, context: WorkspaceContext) async throws -> String {
        let answer = try await ask(.fix(sql: sql, error: error), context: context)
        guard let fixed = answer.sql else { throw ClaudeCLIError.invalidOutput(answer.text) }
        return fixed
    }

    /// Natural-language filter → a SQL boolean condition for the WHERE clause of `table` (no data is sent).
    @MainActor
    public static func filterCondition(_ description: String, schema: String, table: String, columns: [ResultColumn],
                                       context: WorkspaceContext) async throws -> String {
        let cols = columns.map { "\($0.name) \($0.typeName)" }.joined(separator: ", ")
        let prompt = """
        Turn this description into a single SQL boolean condition for the WHERE clause of \(schema).\(table) \
        (columns: \(cols)). Use only these columns; use the current date functions of the dialect for relative dates.
        Description: \(description)
        Reply with the condition alone in one ```sql block — no SELECT, no WHERE keyword, no trailing semicolon.
        """
        let answer = try await ask(.custom(title: "Filter", prompt: prompt, attachments: [], focus: table), context: context,
                                   model: "haiku", useTools: false)
        guard var condition = answer.sql?.trimmingCharacters(in: .whitespacesAndNewlines), !condition.isEmpty else {
            throw ClaudeCLIError.invalidOutput(answer.text)
        }
        if condition.uppercased().hasPrefix("WHERE ") { condition = String(condition.dropFirst(6)) }
        while condition.hasSuffix(";") { condition.removeLast() }
        return condition.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
