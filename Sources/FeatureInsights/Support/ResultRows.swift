import Foundation
import MTPCore

/// Typed, crash-free access to one row of a QueryResult by column name.
struct ResultRow {
    let values: [String?]
    let columns: [String: Int]

    subscript(_ name: String) -> String? {
        guard let i = columns[name], i < values.count else { return nil }
        return values[i]
    }

    func string(_ name: String) -> String? {
        guard let s = self[name], !s.isEmpty else { return nil }
        return s
    }

    func text(_ name: String) -> String { self[name] ?? "" }

    func double(_ name: String) -> Double? {
        guard let s = self[name], let d = Double(s.trimmingCharacters(in: .whitespaces)), d.isFinite else { return nil }
        return d
    }

    func int(_ name: String) -> Int64? {
        guard let s = self[name]?.trimmingCharacters(in: .whitespaces) else { return nil }
        if let i = Int64(s) { return i }
        guard let d = Double(s), d.isFinite, d >= Double(Int64.min), d < Double(Int64.max) else { return nil }
        return Int64(d)
    }

    func bool(_ name: String) -> Bool? {
        switch self[name]?.lowercased() {
        case "t", "true", "1", "yes", "on": return true
        case "f", "false", "0", "no", "off": return false
        default: return nil
        }
    }

    func flag(_ name: String) -> Bool { bool(name) ?? false }
}

extension QueryResult {
    var typedRows: [ResultRow] {
        var map: [String: Int] = [:]
        for (i, c) in columns.enumerated() where map[c.name] == nil { map[c.name] = i }
        return rows.map { ResultRow(values: $0, columns: map) }
    }
}

extension Error {
    /// Server message without the "ERROR: " severity prefix, plus hint when there is one.
    var insightsMessage: String {
        if let db = self as? DatabaseError {
            var m = db.message
            for prefix in ["ERROR: ", "FATAL: "] where m.hasPrefix(prefix) { m.removeFirst(prefix.count) }
            if let hint = db.hint, !hint.isEmpty { m += "\n\(hint)" }
            return m
        }
        return localizedDescription
    }

    /// Permission problems are common on RDS for non-superusers.
    var isPermissionDenied: Bool { (self as? DatabaseError)?.sqlState == "42501" }
}
