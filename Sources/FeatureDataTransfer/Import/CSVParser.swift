import Foundation

/// One parsed record. `quoted[i]` tells whether field i was enclosed in quotes (so `""` differs from an empty field).
public struct CSVRecord: Equatable, Sendable {
    public var fields: [String]
    public var quoted: [Bool]
    /// 1-based physical line where the record starts.
    public var line: Int
}

/// Streaming RFC 4180 parser working on bytes: feed chunks of any size, then call `finish`.
///
/// Handles quoted fields, doubled quotes, delimiters and line breaks inside quotes, LF / CRLF / CR line endings,
/// a UTF-8 byte order mark, and skips blank lines. Malformed input is read leniently: a quote inside an unquoted
/// field is kept literally, text after a closing quote is appended, and an unterminated quote runs to end of input.
/// Input must be UTF-8 or Latin-1 bytes (the reader transcodes UTF-16 first); the delimiter must be ASCII.
public struct CSVParser {
    public enum FieldEncoding: Sendable { case utf8, latin1 }

    public let delimiter: UInt8
    public let quote: UInt8
    public let encoding: FieldEncoding
    /// Set when input ended inside a quoted field.
    public private(set) var hadUnterminatedQuote = false

    private enum State { case fieldStart, unquoted, quoted, quoteInQuoted }

    private var state = State.fieldStart
    private var field: [UInt8] = []
    private var fieldQuoted = false
    private var fields: [String] = []
    private var quotedFlags: [Bool] = []
    private var line = 1
    private var recordLine = 1
    private var skipLF = false
    private var bomPending: [UInt8]? = []

    public init(delimiter: UInt8 = UInt8(ascii: ","), quote: UInt8 = UInt8(ascii: "\""), encoding: FieldEncoding = .utf8) {
        self.delimiter = delimiter
        self.quote = quote
        self.encoding = encoding
        if encoding == .latin1 { bomPending = nil }
    }

    public mutating func feed<C: Collection>(_ bytes: C, emit: (CSVRecord) -> Void) where C.Element == UInt8 {
        if var prefix = bomPending {
            prefix.append(contentsOf: bytes)
            if prefix.count < 3 {
                bomPending = prefix
                return
            }
            bomPending = nil
            let body = prefix.starts(with: [0xEF, 0xBB, 0xBF]) ? Array(prefix.dropFirst(3)) : prefix
            consume(body, emit: emit)
            return
        }
        consume(bytes, emit: emit)
    }

    public mutating func finish(emit: (CSVRecord) -> Void) {
        if let prefix = bomPending {
            bomPending = nil
            consume(prefix.starts(with: [0xEF, 0xBB, 0xBF]) ? Array(prefix.dropFirst(3)) : prefix, emit: emit)
        }
        switch state {
        case .quoted:
            hadUnterminatedQuote = true
            endField()
            endRecord(emit)
        case .unquoted, .quoteInQuoted:
            endField()
            endRecord(emit)
        case .fieldStart:
            if !fields.isEmpty {
                endField()
                endRecord(emit)
            }
        }
        state = .fieldStart
    }

    private mutating func consume<C: Collection>(_ bytes: C, emit: (CSVRecord) -> Void) where C.Element == UInt8 {
        let LF: UInt8 = 0x0A, CR: UInt8 = 0x0D
        for b in bytes {
            if skipLF {
                skipLF = false
                if b == LF { continue }
            }
            switch state {
            case .fieldStart:
                if b == quote {
                    state = .quoted
                    fieldQuoted = true
                } else if b == delimiter {
                    endField()
                } else if b == LF || b == CR {
                    endField()
                    newline(b)
                    endRecord(emit)
                } else {
                    field.append(b)
                    state = .unquoted
                }
            case .unquoted:
                if b == delimiter {
                    endField()
                    state = .fieldStart
                } else if b == LF || b == CR {
                    endField()
                    newline(b)
                    endRecord(emit)
                    state = .fieldStart
                } else {
                    field.append(b)
                }
            case .quoted:
                if b == quote {
                    state = .quoteInQuoted
                } else {
                    if b == LF { line += 1 }
                    field.append(b)
                }
            case .quoteInQuoted:
                if b == quote {
                    field.append(quote)
                    state = .quoted
                } else if b == delimiter {
                    endField()
                    state = .fieldStart
                } else if b == LF || b == CR {
                    endField()
                    newline(b)
                    endRecord(emit)
                    state = .fieldStart
                } else {
                    field.append(b)
                    state = .unquoted
                }
            }
        }
    }

    private mutating func newline(_ b: UInt8) {
        line += 1
        if b == 0x0D { skipLF = true }
    }

    private mutating func endField() {
        fields.append(decode(field))
        quotedFlags.append(fieldQuoted)
        field.removeAll(keepingCapacity: true)
        fieldQuoted = false
    }

    private mutating func endRecord(_ emit: (CSVRecord) -> Void) {
        let blank = fields.count == 1 && fields[0].isEmpty && !quotedFlags[0]
        if !blank { emit(CSVRecord(fields: fields, quoted: quotedFlags, line: recordLine)) }
        fields.removeAll(keepingCapacity: true)
        quotedFlags.removeAll(keepingCapacity: true)
        recordLine = line
    }

    private func decode(_ bytes: [UInt8]) -> String {
        switch encoding {
        case .utf8:
            return String(decoding: bytes, as: UTF8.self)
        case .latin1:
            var s = String.UnicodeScalarView()
            s.append(contentsOf: bytes.map { Unicode.Scalar($0) })
            return String(s)
        }
    }

    /// Convenience for tests and small inputs.
    public static func parse(_ text: String, delimiter: Character = ",") -> [[String]] {
        records(Data(text.utf8), delimiter: delimiter).map(\.fields)
    }

    public static func records(_ data: Data, delimiter: Character = ",", encoding: FieldEncoding = .utf8) -> [CSVRecord] {
        var p = CSVParser(delimiter: delimiter.asciiValue ?? UInt8(ascii: ","), encoding: encoding)
        var out: [CSVRecord] = []
        p.feed(data) { out.append($0) }
        p.finish { out.append($0) }
        return out
    }
}
