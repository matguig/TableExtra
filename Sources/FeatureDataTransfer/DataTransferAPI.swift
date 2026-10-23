import MTPCore
import MTPUIKit
import SwiftUI
import UniformTypeIdentifiers

// Public entry points used by the app. Keep these signatures stable.
// Views live in their own files: ExportView, ImportCSVView, BackupView, RestoreView, TablePlusImportView.

public enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case csv = "CSV", tsv = "TSV", json = "JSON", jsonLines = "JSON Lines", sqlInsert = "SQL INSERT", markdown = "Markdown"
    public var id: String { rawValue }

    public var fileExtension: String {
        switch self {
        case .csv: return "csv"
        case .tsv: return "tsv"
        case .json: return "json"
        case .jsonLines: return "jsonl"
        case .sqlInsert: return "sql"
        case .markdown: return "md"
        }
    }

    public var contentType: UTType {
        switch self {
        case .csv: return .commaSeparatedText
        case .tsv: return .tabSeparatedText
        case .json: return .json
        case .jsonLines: return UTType(filenameExtension: "jsonl") ?? .plainText
        case .sqlInsert: return UTType(filenameExtension: "sql") ?? .plainText
        case .markdown: return UTType(filenameExtension: "md") ?? .plainText
        }
    }
}

public enum ExportSource {
    /// An already-loaded result (query tab, current page, selected rows).
    case result(QueryResult, suggestedName: String, tableName: String?)
    /// Whole tables, streamed from the server page by page.
    case tables(schema: String, names: [String])
}

public enum DataExporter {
    /// Renders rows in memory (clipboard "Copy as…" and small exports).
    public static func render(_ result: QueryResult, format: ExportFormat, tableName: String? = nil, dialect: SQLDialect = SQLDialect(kind: .postgres)) -> String {
        render(result, format: format, options: ExportOptions(), tableName: tableName, dialect: dialect)
    }

    /// Same as above with explicit options. `tableName` may be "schema.table".
    public static func render(_ result: QueryResult, format: ExportFormat, options: ExportOptions, tableName: String? = nil, schema: String? = nil,
                              dialect: SQLDialect = SQLDialect(kind: .postgres)) -> String {
        var encoder = ExportEncoder(format: format, columns: result.columns, options: options, tableName: tableName, schema: schema, dialect: dialect)
        var out = encoder.header()
        out += encoder.encode(result.rows)
        out += encoder.footer()
        return out
    }
}
