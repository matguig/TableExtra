import Foundation

/// Order-preserving JSON value. Numbers keep their source text so bigint/numeric never lose precision.
public indirect enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(String)
    case string(String)
    case array([JSONValue])
    case object([(String, JSONValue)])

    public static func == (a: JSONValue, b: JSONValue) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case let (.bool(x), .bool(y)): return x == y
        case let (.number(x), .number(y)): return x == y
        case let (.string(x), .string(y)): return x == y
        case let (.array(x), .array(y)): return x == y
        case let (.object(x), .object(y)): return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }
}

public enum JSONText {
    /// Strict RFC 8259 parse of a whole document (surrounding whitespace allowed).
    public static func parse(_ text: String) -> JSONValue? {
        var p = Parser(bytes: Array(text.utf8))
        guard let v = p.value() else { return nil }
        p.skipWhitespace()
        return p.atEnd ? v : nil
    }

    public static func parse(data: Data) -> JSONValue? {
        var bytes = [UInt8](data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        var p = Parser(bytes: bytes)
        guard let v = p.value() else { return nil }
        p.skipWhitespace()
        return p.atEnd ? v : nil
    }

    /// Parses newline-delimited JSON (one value per line, blank lines ignored).
    public static func parseLines(data: Data) -> [JSONValue]? {
        var bytes = [UInt8](data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        var p = Parser(bytes: bytes)
        var out: [JSONValue] = []
        while true {
            p.skipWhitespace()
            if p.atEnd { return out }
            guard let v = p.value() else { return nil }
            out.append(v)
        }
    }

    public static func quote(_ s: String) -> String {
        var out = "\""
        out.reserveCapacity(s.utf8.count + 2)
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            default:
                if u.value < 0x20 {
                    out += String(format: "\\u%04x", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        out += "\""
        return out
    }

    /// Serialises `value`; `level` is the indentation depth of the line the value starts on.
    public static func write(_ value: JSONValue, pretty: Bool, level: Int = 0, into out: inout String) {
        switch value {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += n
        case .string(let s): out += quote(s)
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                if pretty { out += "\n" + indent(level + 1) }
                write(item, pretty: pretty, level: level + 1, into: &out)
            }
            if pretty { out += "\n" + indent(level) }
            out += "]"
        case .object(let members):
            if members.isEmpty { out += "{}"; return }
            out += "{"
            for (i, (k, v)) in members.enumerated() {
                if i > 0 { out += "," }
                if pretty { out += "\n" + indent(level + 1) }
                out += quote(k)
                out += pretty ? ": " : ":"
                write(v, pretty: pretty, level: level + 1, into: &out)
            }
            if pretty { out += "\n" + indent(level) }
            out += "}"
        }
    }

    public static func string(_ value: JSONValue, pretty: Bool = false) -> String {
        var s = ""
        write(value, pretty: pretty, into: &s)
        return s
    }

    static func indent(_ level: Int) -> String { String(repeating: "  ", count: level) }

    /// JSON number grammar: -?(0|[1-9]\d*)(\.\d+)?([eE][+-]?\d+)?
    public static func isNumber(_ s: String) -> Bool {
        var p = Parser(bytes: Array(s.utf8))
        guard p.number() != nil else { return false }
        return p.atEnd
    }

    struct Parser {
        let bytes: [UInt8]
        var i = 0
        var depth = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        var atEnd: Bool { i >= bytes.count }

        mutating func skipWhitespace() {
            while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x0A || bytes[i] == 0x0D || bytes[i] == 0x09 { i += 1 }
        }

        mutating func value() -> JSONValue? {
            skipWhitespace()
            guard i < bytes.count else { return nil }
            switch bytes[i] {
            case UInt8(ascii: "{"): return object()
            case UInt8(ascii: "["): return array()
            case UInt8(ascii: "\""): return string().map(JSONValue.string)
            case UInt8(ascii: "t"): return literal("true", .bool(true))
            case UInt8(ascii: "f"): return literal("false", .bool(false))
            case UInt8(ascii: "n"): return literal("null", .null)
            default: return number().map(JSONValue.number)
            }
        }

        mutating func literal(_ word: String, _ v: JSONValue) -> JSONValue? {
            let w = Array(word.utf8)
            guard i + w.count <= bytes.count, Array(bytes[i..<(i + w.count)]) == w else { return nil }
            i += w.count
            return v
        }

        mutating func object() -> JSONValue? {
            depth += 1
            defer { depth -= 1 }
            guard depth < 512 else { return nil }
            i += 1
            var members: [(String, JSONValue)] = []
            skipWhitespace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object([]) }
            while true {
                skipWhitespace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: "\""), let key = string() else { return nil }
                skipWhitespace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { return nil }
                i += 1
                guard let v = value() else { return nil }
                members.append((key, v))
                skipWhitespace()
                guard i < bytes.count else { return nil }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
                return nil
            }
        }

        mutating func array() -> JSONValue? {
            depth += 1
            defer { depth -= 1 }
            guard depth < 512 else { return nil }
            i += 1
            var items: [JSONValue] = []
            skipWhitespace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array([]) }
            while true {
                guard let v = value() else { return nil }
                items.append(v)
                skipWhitespace()
                guard i < bytes.count else { return nil }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                return nil
            }
        }

        mutating func string() -> String? {
            i += 1
            var buf: [UInt8] = []
            while i < bytes.count {
                let b = bytes[i]
                switch b {
                case UInt8(ascii: "\""):
                    i += 1
                    return String(decoding: buf, as: UTF8.self)
                case UInt8(ascii: "\\"):
                    i += 1
                    guard i < bytes.count else { return nil }
                    let e = bytes[i]
                    i += 1
                    switch e {
                    case UInt8(ascii: "\""): buf.append(0x22)
                    case UInt8(ascii: "\\"): buf.append(0x5C)
                    case UInt8(ascii: "/"): buf.append(0x2F)
                    case UInt8(ascii: "b"): buf.append(0x08)
                    case UInt8(ascii: "f"): buf.append(0x0C)
                    case UInt8(ascii: "n"): buf.append(0x0A)
                    case UInt8(ascii: "r"): buf.append(0x0D)
                    case UInt8(ascii: "t"): buf.append(0x09)
                    case UInt8(ascii: "u"):
                        guard var code = hex4() else { return nil }
                        if (0xD800...0xDBFF).contains(code) {
                            // Surrogate pair.
                            if i + 1 < bytes.count, bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") {
                                i += 2
                                guard let low = hex4(), (0xDC00...0xDFFF).contains(low) else { return nil }
                                code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                            } else {
                                code = 0xFFFD
                            }
                        } else if (0xDC00...0xDFFF).contains(code) {
                            code = 0xFFFD
                        }
                        buf.append(contentsOf: Array(String(Unicode.Scalar(code) ?? "\u{FFFD}").utf8))
                    default:
                        return nil
                    }
                default:
                    if b < 0x20 { return nil }
                    buf.append(b)
                    i += 1
                }
            }
            return nil
        }

        mutating func hex4() -> UInt32? {
            guard i + 4 <= bytes.count else { return nil }
            var v: UInt32 = 0
            for _ in 0..<4 {
                let c = bytes[i]
                let d: UInt32
                switch c {
                case 0x30...0x39: d = UInt32(c - 0x30)
                case 0x41...0x46: d = UInt32(c - 0x41 + 10)
                case 0x61...0x66: d = UInt32(c - 0x61 + 10)
                default: return nil
                }
                v = v * 16 + d
                i += 1
            }
            return v
        }

        mutating func number() -> String? {
            let start = i
            func digit(_ j: Int) -> Bool { j < bytes.count && bytes[j] >= 0x30 && bytes[j] <= 0x39 }
            if i < bytes.count, bytes[i] == UInt8(ascii: "-") { i += 1 }
            guard digit(i) else { i = start; return nil }
            if bytes[i] == 0x30 {
                i += 1
            } else {
                while digit(i) { i += 1 }
            }
            if i < bytes.count, bytes[i] == UInt8(ascii: ".") {
                i += 1
                guard digit(i) else { i = start; return nil }
                while digit(i) { i += 1 }
            }
            if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
                i += 1
                if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
                guard digit(i) else { i = start; return nil }
                while digit(i) { i += 1 }
            }
            return String(decoding: bytes[start..<i], as: UTF8.self)
        }
    }
}
