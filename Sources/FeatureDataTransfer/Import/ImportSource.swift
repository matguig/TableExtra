import Foundation
import MTPCore

/// One input row. CSV values are never nil; JSON nulls and missing keys are.
public struct ImportRow: Sendable, Equatable {
    public var values: [String?]
    /// Whether the value was quoted in the file (a quoted "NULL" or "" stays a string).
    public var quoted: [Bool]
    /// Line (CSV) or record number (JSON) for error reports.
    public var line: Int

    public init(values: [String?], quoted: [Bool], line: Int) {
        self.values = values
        self.quoted = quoted
        self.line = line
    }
}

public enum ImportFileKind: String, Sendable {
    case delimited, json
}

/// How to read a delimited file (auto-detected, then adjustable in the UI).
public struct ImportFileSettings: Equatable, Sendable {
    public var encoding: DetectedEncoding
    public var delimiter: UInt8
    public var hasHeader: Bool

    public init(encoding: DetectedEncoding = DetectedEncoding(encoding: .utf8, bomLength: 0), delimiter: UInt8 = UInt8(ascii: ","), hasHeader: Bool = true) {
        self.encoding = encoding
        self.delimiter = delimiter
        self.hasHeader = hasHeader
    }
}

public protocol ImportRowSource: AnyObject {
    var columnNames: [String] { get }
    /// Up to `max` rows; empty means end of input.
    func next(_ max: Int) throws -> [ImportRow]
    var fractionRead: Double { get }
}

final class DelimitedRowSource: ImportRowSource {
    let reader: DelimitedFileReader
    let columnNames: [String]
    private var pending: [ImportRow] = []

    init(url: URL, settings: ImportFileSettings) throws {
        reader = try DelimitedFileReader(url: url, encoding: settings.encoding, delimiter: settings.delimiter)
        let first = try reader.next(1).first
        if settings.hasHeader {
            columnNames = TypeInference.columnNames(from: first?.fields ?? [])
        } else {
            let n = first?.fields.count ?? 0
            columnNames = (0..<n).map { "column_\($0 + 1)" }
            if let first { pending = [Self.row(first)] }
        }
    }

    static func row(_ r: CSVRecord) -> ImportRow { ImportRow(values: r.fields, quoted: r.quoted, line: r.line) }

    func next(_ max: Int) throws -> [ImportRow] {
        var out = pending
        pending = []
        if out.count < max { out += try reader.next(max - out.count).map(Self.row) }
        return out
    }

    var fractionRead: Double { reader.fractionRead }
}

/// A JSON array of objects, or JSON Lines; nested values become JSON text.
final class JSONRowSource: ImportRowSource {
    let columnNames: [String]
    private let rows: [ImportRow]
    private var index = 0

    init(data: Data) throws {
        let values: [JSONValue]
        if let doc = JSONText.parse(data: data) {
            switch doc {
            case .array(let items): values = items
            case .object: values = [doc]
            default: throw DatabaseError("The JSON file must contain an array of objects")
            }
        } else if let lines = JSONText.parseLines(data: data) {
            values = lines
        } else {
            throw DatabaseError("The file is not valid JSON or JSON Lines")
        }
        var names: [String] = []
        var seen: Set<String> = []
        for case .object(let members) in values {
            for (k, _) in members where !seen.contains(k) {
                seen.insert(k)
                names.append(k)
            }
        }
        guard !names.isEmpty else { throw DatabaseError("No objects found in the JSON file") }
        let position = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($1, $0) })
        var out: [ImportRow] = []
        out.reserveCapacity(values.count)
        for (n, v) in values.enumerated() {
            guard case .object(let members) = v else { continue }
            var row = [String?](repeating: nil, count: names.count)
            var quoted = [Bool](repeating: false, count: names.count)
            for (k, value) in members {
                guard let i = position[k] else { continue }
                switch value {
                case .null: row[i] = nil
                case .bool(let b): row[i] = b ? "true" : "false"
                case .number(let s): row[i] = s
                case .string(let s): row[i] = s; quoted[i] = true
                case .array, .object: row[i] = JSONText.string(value); quoted[i] = true
                }
            }
            out.append(ImportRow(values: row, quoted: quoted, line: n + 1))
        }
        columnNames = names
        rows = out
    }

    func next(_ max: Int) throws -> [ImportRow] {
        let end = min(rows.count, index + max)
        defer { index = end }
        return Array(rows[index..<end])
    }

    var fractionRead: Double { rows.isEmpty ? 1 : Double(index) / Double(rows.count) }
}

/// First rows of a file plus what was detected about it.
public struct ImportFilePreview: Sendable {
    public var url: URL
    public var kind: ImportFileKind
    public var settings: ImportFileSettings
    public var columns: [String]
    public var rows: [ImportRow]
    public var inferredTypes: [InferredType]
    public var fileSize: Int64
    /// True when `rows` holds the whole file.
    public var isComplete: Bool

    public var result: QueryResult {
        let cols = zip(columns, inferredTypes).map { ResultColumn(name: $0, typeName: $1.rawValue, kind: $1.valueKind) }
        let data = rows.prefix(200).map { r in (0..<columns.count).map { $0 < r.values.count ? r.values[$0] : nil } }
        return QueryResult(columns: cols, rows: Array(data), commandTag: "PREVIEW", statement: url.path)
    }
}

public enum ImportFileLoader {
    public static let sampleRows = 1_000

    public static func kind(of url: URL) -> ImportFileKind {
        switch url.pathExtension.lowercased() {
        case "json", "jsonl", "ndjson": return .json
        case "csv", "tsv", "tab", "psv": return .delimited
        default:
            guard let h = try? FileHandle(forReadingFrom: url) else { return .delimited }
            defer { try? h.close() }
            let head = (try? h.read(upToCount: 512)) ?? Data()
            let text = String(decoding: head, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
            return text.hasPrefix("[") || text.hasPrefix("{") ? .json : .delimited
        }
    }

    public static func sniff(_ url: URL) throws -> ImportFileSettings {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        let sample = try h.read(upToCount: 256 * 1024) ?? Data()
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        let r = CSVSniffer.sniff(sample, isComplete: Int64(sample.count) >= size)
        var delimiter = r.delimiter
        if url.pathExtension.lowercased() == "tsv" || url.pathExtension.lowercased() == "tab" { delimiter = UInt8(ascii: "\t") }
        return ImportFileSettings(encoding: r.encoding, delimiter: delimiter, hasHeader: r.hasHeader)
    }

    public static func makeSource(_ url: URL, kind: ImportFileKind, settings: ImportFileSettings) throws -> ImportRowSource {
        switch kind {
        case .delimited: return try DelimitedRowSource(url: url, settings: settings)
        case .json: return try JSONRowSource(data: Data(contentsOf: url))
        }
    }

    public static func preview(_ url: URL, kind: ImportFileKind, settings: ImportFileSettings) throws -> ImportFilePreview {
        let source = try makeSource(url, kind: kind, settings: settings)
        let rows = try source.next(sampleRows)
        let more = try source.next(1)
        let names = source.columnNames
        let types = names.indices.map { i in TypeInference.infer(rows.lazy.map { i < $0.values.count ? $0.values[i] : nil }) }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        return ImportFilePreview(url: url, kind: kind, settings: settings, columns: names, rows: rows, inferredTypes: types,
                                 fileSize: size, isComplete: more.isEmpty)
    }
}
