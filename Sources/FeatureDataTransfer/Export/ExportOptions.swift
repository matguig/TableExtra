import Foundation

/// Knobs for every export format; each format reads the ones that apply to it.
public struct ExportOptions: Sendable, Hashable {
    public enum NullStyle: String, CaseIterable, Identifiable, Sendable {
        case empty = "Empty"
        case keyword = "NULL"
        public var id: String { rawValue }
    }

    public enum LineEnding: String, CaseIterable, Identifiable, Sendable {
        case lf = "LF (macOS, Linux)"
        case crlf = "CRLF (Windows, RFC 4180)"
        public var id: String { rawValue }
        public var string: String { self == .lf ? "\n" : "\r\n" }
    }

    /// CSV field separator (TSV always uses a tab). Only the first character is used.
    public var delimiter: String
    /// CSV, TSV: first line with column names. Markdown always has a header.
    public var includeHeader: Bool
    /// CSV, TSV, Markdown: how SQL NULL is written. JSON always uses null, SQL always NULL.
    public var nullStyle: NullStyle
    public var lineEnding: LineEnding
    /// Prefix files with a UTF-8 byte order mark (helps Excel detect the encoding).
    public var utf8BOM: Bool
    /// JSON: indented output. JSON Lines is always compact.
    public var prettyJSON: Bool
    /// SQL: rows per INSERT statement (1 = one INSERT per row).
    public var sqlBatchSize: Int
    /// SQL table export: emit CREATE TABLE before the rows.
    public var includeCreateTable: Bool
    /// SQL table export: emit DROP TABLE IF EXISTS before CREATE TABLE.
    public var includeDropTable: Bool

    public init(delimiter: String = ",", includeHeader: Bool = true, nullStyle: NullStyle = .empty, lineEnding: LineEnding = .lf,
                utf8BOM: Bool = false, prettyJSON: Bool = true, sqlBatchSize: Int = 100, includeCreateTable: Bool = false,
                includeDropTable: Bool = false) {
        self.delimiter = delimiter
        self.includeHeader = includeHeader
        self.nullStyle = nullStyle
        self.lineEnding = lineEnding
        self.utf8BOM = utf8BOM
        self.prettyJSON = prettyJSON
        self.sqlBatchSize = sqlBatchSize
        self.includeCreateTable = includeCreateTable
        self.includeDropTable = includeDropTable
    }

    var delimiterCharacter: Character { delimiter.first ?? "," }
    var effectiveBatchSize: Int { max(1, sqlBatchSize) }

    /// Common separators offered by the UI.
    public static let delimiterChoices: [(label: String, value: String)] = [
        ("Comma  ,", ","), ("Semicolon  ;", ";"), ("Tab", "\t"), ("Pipe  |", "|"),
    ]
}
