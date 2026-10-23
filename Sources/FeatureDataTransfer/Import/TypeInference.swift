import Foundation
import MTPCore

/// Column type guessed from sample values when importing into a new table.
public enum InferredType: String, CaseIterable, Identifiable, Sendable {
    case integer, bigint, numeric, boolean, date, timestamp, timestamptz, uuid, json, text

    public var id: String { rawValue }

    public func sqlType(for dialect: SQLDialect) -> String {
        switch dialect.kind {
        case .postgres:
            switch self {
            case .json: return "jsonb"
            default: return rawValue
            }
        case .sqlite:
            switch self {
            case .integer, .bigint: return "INTEGER"
            case .numeric: return "NUMERIC"
            case .boolean: return "BOOLEAN"
            case .date: return "DATE"
            case .timestamp, .timestamptz: return "DATETIME"
            case .uuid, .json, .text: return "TEXT"
            }
        }
    }

    /// Choices offered for a new table's columns.
    public static func choices(for dialect: SQLDialect) -> [InferredType] {
        dialect.kind == .postgres ? allCases : [.integer, .numeric, .boolean, .date, .timestamp, .text]
    }

    var valueKind: ValueKind {
        switch self {
        case .integer, .bigint: return .integer
        case .numeric: return .decimal
        case .boolean: return .boolean
        case .date: return .date
        case .timestamp, .timestamptz: return .timestamp
        case .uuid: return .uuid
        case .json: return .json
        case .text: return .text
        }
    }
}

public enum TypeInference {
    /// Narrowest type that fits every non-empty value; empty samples give text.
    public static func infer<S: Sequence>(_ values: S) -> InferredType where S.Element == String? {
        var any = false
        var int = true, bigint = true, numeric = true, bool = true, date = true, ts = true, zone = false, uuid = true, json = true
        for raw in values {
            guard let raw else { continue }
            let v = raw.trimmingCharacters(in: .whitespaces)
            if v.isEmpty { continue }
            any = true
            if int || bigint {
                switch integerFit(v) {
                case 0: int = false; bigint = false
                case 2: int = false
                default: break
                }
            }
            if numeric && !isDecimal(v) { numeric = false }
            if bool && !booleanWords.contains(v.lowercased()) { bool = false }
            if date || ts {
                let d = isDate(v)
                if !d { date = false }
                if !d {
                    if let z = timestampZone(v) { zone = zone || z } else { ts = false }
                }
            }
            if uuid && !isUUID(v) { uuid = false }
            if json { json = (v.hasPrefix("{") || v.hasPrefix("[")) && JSONText.parse(v) != nil }
            if !(int || bigint || numeric || bool || date || ts || uuid || json) { return .text }
        }
        guard any else { return .text }
        if bool { return .boolean }
        if int { return .integer }
        if bigint { return .bigint }
        if numeric { return .numeric }
        if date { return .date }
        if ts { return zone ? .timestamptz : .timestamp }
        if uuid { return .uuid }
        if json { return .json }
        return .text
    }

    static let booleanWords: Set<String> = ["true", "false", "t", "f", "yes", "no"]

    /// 0 = not an integer, 1 = fits int4, 2 = fits int8 only. Leading zeros ("007", zip codes) are not integers.
    static func integerFit(_ v: String) -> Int {
        var digits = Substring(v)
        if digits.first == "-" || digits.first == "+" { digits = digits.dropFirst() }
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return 0 }
        if digits.count > 1 && digits.first == "0" { return 0 }
        guard let n = Int64(v.hasPrefix("+") ? String(v.dropFirst()) : v) else { return 0 }
        return (Int64(Int32.min)...Int64(Int32.max)).contains(n) ? 1 : 2
    }

    static func isDecimal(_ v: String) -> Bool {
        guard v.range(of: "^[+-]?([0-9]+(\\.[0-9]*)?|\\.[0-9]+)([eE][+-]?[0-9]+)?$", options: .regularExpression) != nil else { return false }
        var body = Substring(v)
        if body.first == "-" || body.first == "+" { body = body.dropFirst() }
        // Keep identifiers such as "0012.5" as text.
        if body.count > 1, body.first == "0", body.dropFirst().first?.isNumber == true { return false }
        return true
    }

    static func isDate(_ v: String) -> Bool {
        guard v.count == 10, v.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil else { return false }
        let p = v.split(separator: "-").compactMap { Int($0) }
        return p.count == 3 && (1...12).contains(p[1]) && (1...31).contains(p[2])
    }

    /// nil when not a timestamp; otherwise whether it carries a zone (Z or ±hh[:mm]).
    static func timestampZone(_ v: String) -> Bool? {
        let pattern = "^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}(:[0-9]{2}(\\.[0-9]+)?)?\\s?(Z|[+-][0-9]{2}(:?[0-9]{2})?)?$"
        guard v.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        guard isDate(String(v.prefix(10))) else { return nil }
        let tail = v.dropFirst(16)
        return tail.contains("Z") || tail.contains("z") || tail.contains("+") || tail.contains("-")
    }

    static func isUUID(_ v: String) -> Bool {
        v.count == 36 && v.range(of: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", options: .regularExpression) != nil
    }

    /// False when sampled file values clearly won't load into a column of `kind` (shown as a hint, not enforced).
    public static func isCompatible(_ inferred: InferredType, with kind: ValueKind) -> Bool {
        switch kind {
        case .integer: return inferred == .integer || inferred == .bigint
        case .decimal: return [.integer, .bigint, .numeric].contains(inferred)
        case .boolean: return inferred == .boolean || inferred == .integer
        case .date: return [.date, .timestamp, .timestamptz].contains(inferred)
        case .timestamp: return [.date, .timestamp, .timestamptz].contains(inferred)
        case .uuid: return inferred == .uuid
        case .json: return inferred == .json || inferred == .integer || inferred == .numeric || inferred == .boolean
        default: return true
        }
    }

    /// Unique, SQL-friendly column names from a header row ("" → column_3, duplicates → name_2).
    public static func columnNames(from header: [String]) -> [String] {
        var seen: [String: Int] = [:]
        return header.enumerated().map { i, raw in
            var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { name = "column_\(i + 1)" }
            let n = (seen[name.lowercased()] ?? 0) + 1
            seen[name.lowercased()] = n
            return n == 1 ? name : "\(name)_\(n)"
        }
    }
}

public struct CSVSniffResult: Equatable, Sendable {
    public var encoding: DetectedEncoding
    public var delimiter: UInt8
    public var hasHeader: Bool
}

public enum CSVSniffer {
    public static let candidates: [UInt8] = [UInt8(ascii: ","), UInt8(ascii: ";"), UInt8(ascii: "\t"), UInt8(ascii: "|")]

    /// `sample` is the start of the file; `isComplete` tells whether it is the whole file.
    public static func sniff(_ sample: Data, isComplete: Bool) -> CSVSniffResult {
        let enc = TextEncodingDetector.detect(sample)
        var bytes: [UInt8]
        switch enc.encoding {
        case .utf16LE, .utf16BE:
            var t = UTF16Transcoder(bigEndian: enc.encoding == .utf16BE)
            bytes = t.transcode(Data(sample.dropFirst(enc.bomLength)), final: true)
        default:
            bytes = [UInt8](sample.dropFirst(enc.bomLength))
        }
        if !isComplete, let lastLF = bytes.lastIndex(of: 0x0A) { bytes = Array(bytes[...lastLF]) }
        let fieldEncoding: CSVParser.FieldEncoding = enc.encoding == .latin1 ? .latin1 : .utf8
        let delimiter = detectDelimiter(bytes, encoding: fieldEncoding)
        let rows = parse(bytes, delimiter: delimiter, encoding: fieldEncoding, limit: 100)
        return CSVSniffResult(encoding: enc, delimiter: delimiter, hasHeader: detectHeader(rows))
    }

    static func parse(_ bytes: [UInt8], delimiter: UInt8, encoding: CSVParser.FieldEncoding, limit: Int) -> [[String]] {
        var p = CSVParser(delimiter: delimiter, encoding: encoding)
        var out: [[String]] = []
        p.feed(bytes) { if out.count < limit { out.append($0.fields) } }
        p.finish { if out.count < limit { out.append($0.fields) } }
        return out
    }

    /// Picks the separator giving the most consistent field count (>1); ties keep the order , ; tab |.
    public static func detectDelimiter(_ bytes: [UInt8], encoding: CSVParser.FieldEncoding = .utf8) -> UInt8 {
        var best = candidates[0]
        var bestScore = 0.0
        for d in candidates {
            let rows = parse(bytes, delimiter: d, encoding: encoding, limit: 50)
            guard !rows.isEmpty else { continue }
            var freq: [Int: Int] = [:]
            for r in rows { freq[r.count, default: 0] += 1 }
            guard let (mode, count) = freq.max(by: { $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value }), mode > 1 else { continue }
            let score = Double(count) / Double(rows.count) * 100 + Double(min(mode, 100)) / 1000
            if score > bestScore + 1e-9 {
                bestScore = score
                best = d
            }
        }
        return best
    }

    /// A header row is text where the body below holds typed values; all-text files assume a header
    /// when the first row is non-empty and unique.
    public static func detectHeader(_ rows: [[String]]) -> Bool {
        guard let first = rows.first else { return true }
        let body = rows.dropFirst()
        if body.isEmpty { return first.allSatisfy { TypeInference.infer([$0]) == .text } }
        var typedColumns = 0
        for c in first.indices {
            let values = body.map { c < $0.count ? Optional($0[c]) : nil }
            let t = TypeInference.infer(values)
            guard t != .text else { continue }
            typedColumns += 1
            let head = first[c].trimmingCharacters(in: .whitespaces)
            if !head.isEmpty && TypeInference.infer([head]) == .text { return true }
        }
        if typedColumns > 0 { return false }
        let trimmed = first.map { $0.trimmingCharacters(in: .whitespaces) }
        return !trimmed.contains("") && Set(trimmed.map { $0.lowercased() }).count == trimmed.count
    }
}
