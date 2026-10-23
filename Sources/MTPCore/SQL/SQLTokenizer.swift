import Foundation

public enum SQLTokenKind: Sendable, Equatable {
    case whitespace
    case lineComment
    case blockComment
    case string
    case dollarString
    case quotedIdentifier
    case number
    case keyword
    case identifier
    case parameter
    case `operator`
    case comma
    case semicolon
    case openParen
    case closeParen
    case dot
    case other

    public var isTrivia: Bool { self == .whitespace || self == .lineComment || self == .blockComment }
    public var isComment: Bool { self == .lineComment || self == .blockComment }
}

public struct SQLToken: Sendable, Equatable {
    public var kind: SQLTokenKind
    /// UTF-16 range, directly usable as an NSRange in text views.
    public var location: Int
    public var length: Int
    public var text: String

    public var range: NSRange { NSRange(location: location, length: length) }
    public var end: Int { location + length }
    public var upper: String { text.uppercased() }

    public func `is`(_ keyword: String) -> Bool {
        (kind == .keyword || kind == .identifier) && text.caseInsensitiveCompare(keyword) == .orderedSame
    }
}

public enum SQLTokenizer {
    public static func tokenize(_ sql: String) -> [SQLToken] {
        let u = Array(sql.utf16)
        let n = u.count
        var tokens: [SQLToken] = []
        tokens.reserveCapacity(n / 3)
        var i = 0

        func emit(_ kind: SQLTokenKind, _ start: Int, _ end: Int) {
            let text = String(utf16CodeUnits: Array(u[start..<end]), count: end - start)
            var k = kind
            if kind == .identifier, SQLKeywords.all.contains(text.uppercased()) { k = .keyword }
            tokens.append(SQLToken(kind: k, location: start, length: end - start, text: text))
        }

        func isIdentStart(_ c: UInt16) -> Bool {
            (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c >= 128
        }
        func isIdentPart(_ c: UInt16) -> Bool { isIdentStart(c) || isDigit(c) || c == 36 }
        func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
        func isSpace(_ c: UInt16) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 || c == 12 || c == 0xA0 }

        while i < n {
            let c = u[i]
            let start = i
            if isSpace(c) {
                while i < n, isSpace(u[i]) { i += 1 }
                emit(.whitespace, start, i)
            } else if c == 45, i + 1 < n, u[i + 1] == 45 { // --
                while i < n, u[i] != 10 { i += 1 }
                emit(.lineComment, start, i)
            } else if c == 35, i + 1 < n, u[i + 1] == 32 || u[i + 1] == 35 { // "# " comment (MySQL-style); harmless elsewhere
                while i < n, u[i] != 10 { i += 1 }
                emit(.lineComment, start, i)
            } else if c == 47, i + 1 < n, u[i + 1] == 42 { // /* nested */
                i += 2
                var depth = 1
                while i < n, depth > 0 {
                    if u[i] == 47, i + 1 < n, u[i + 1] == 42 { depth += 1; i += 2 }
                    else if u[i] == 42, i + 1 < n, u[i + 1] == 47 { depth -= 1; i += 2 }
                    else { i += 1 }
                }
                emit(.blockComment, start, i)
            } else if c == 39 || ((c == 69 || c == 101) && i + 1 < n && u[i + 1] == 39) { // 'str' or E'str'
                let escapes = c != 39
                i += escapes ? 2 : 1
                while i < n {
                    if escapes, u[i] == 92 { i += 2; continue }
                    if u[i] == 39 {
                        if i + 1 < n, u[i + 1] == 39 { i += 2; continue }
                        i += 1
                        break
                    }
                    i += 1
                }
                emit(.string, start, min(i, n))
                i = min(i, n)
            } else if c == 36, let tagEnd = dollarTagEnd(u, i) { // $tag$ ... $tag$
                let tag = Array(u[i...tagEnd])
                i = tagEnd + 1
                var closed = false
                while i < n {
                    if u[i] == 36, i + tag.count <= n, Array(u[i..<(i + tag.count)]) == tag {
                        i += tag.count
                        closed = true
                        break
                    }
                    i += 1
                }
                if !closed { i = n }
                emit(.dollarString, start, i)
            } else if c == 36, i + 1 < n, isDigit(u[i + 1]) { // $1
                i += 1
                while i < n, isDigit(u[i]) { i += 1 }
                emit(.parameter, start, i)
            } else if c == 34 || c == 96 || c == 91 { // "ident", `ident`, [ident]
                let close: UInt16 = c == 91 ? 93 : c
                i += 1
                while i < n {
                    if u[i] == close {
                        if close != 93, i + 1 < n, u[i + 1] == close { i += 2; continue }
                        i += 1
                        break
                    }
                    i += 1
                }
                emit(.quotedIdentifier, start, min(i, n))
            } else if isDigit(c) || (c == 46 && i + 1 < n && isDigit(u[i + 1])) {
                while i < n, isDigit(u[i]) || u[i] == 46 || u[i] == 95 { i += 1 }
                if i < n, u[i] == 101 || u[i] == 69 {
                    var j = i + 1
                    if j < n, u[j] == 43 || u[j] == 45 { j += 1 }
                    if j < n, isDigit(u[j]) {
                        i = j
                        while i < n, isDigit(u[i]) { i += 1 }
                    }
                }
                emit(.number, start, i)
            } else if isIdentStart(c) {
                while i < n, isIdentPart(u[i]) { i += 1 }
                emit(.identifier, start, i)
            } else if (c == 58 || c == 64) && i + 1 < n && isIdentStart(u[i + 1]) && !(i > 0 && u[i - 1] == 58) { // :name, @name
                i += 1
                while i < n, isIdentPart(u[i]) { i += 1 }
                emit(.parameter, start, i)
            } else if c == 63 { // ?
                i += 1
                while i < n, isDigit(u[i]) { i += 1 }
                emit(.parameter, start, i)
            } else if c == 44 {
                i += 1; emit(.comma, start, i)
            } else if c == 59 {
                i += 1; emit(.semicolon, start, i)
            } else if c == 40 {
                i += 1; emit(.openParen, start, i)
            } else if c == 41 {
                i += 1; emit(.closeParen, start, i)
            } else if c == 46 {
                i += 1; emit(.dot, start, i)
            } else if "+-*/<>=~!@#%^&|`?:".utf16.contains(c) {
                while i < n, "+-*/<>=~!@#%^&|:".utf16.contains(u[i]) {
                    // stop before a comment start
                    if u[i] == 45, i + 1 < n, u[i + 1] == 45, i > start { break }
                    if u[i] == 47, i + 1 < n, u[i + 1] == 42, i > start { break }
                    i += 1
                }
                if i == start { i += 1 }
                emit(.operator, start, i)
            } else {
                i += 1
                emit(.other, start, i)
            }
        }
        return tokens
    }

    /// Index of the closing `$` of a dollar-quote opening tag starting at `i`, if any.
    private static func dollarTagEnd(_ u: [UInt16], _ i: Int) -> Int? {
        var j = i + 1
        while j < u.count {
            let c = u[j]
            if c == 36 { return j }
            let ok = (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || (j > i + 1 && c >= 48 && c <= 57)
            if !ok { return nil }
            j += 1
        }
        return nil
    }
}
