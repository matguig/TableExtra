import Foundation
import MTPCore

/// Compact plain-text renderings for tool results (agents read these, so keep them dense and unambiguous).
enum TextTable {
    static let maxCellWidth = 120

    /// Aligned columns separated by " | ", NULL spelled out, long cells cut with "…".
    static func render(headers: [String], rows: [[String?]], maxChars: Int = 60_000) -> String {
        let cells = rows.map { $0.map { cell($0) } }
        var widths = headers.map(\.count)
        for row in cells {
            for (i, c) in row.enumerated() where i < widths.count { widths[i] = max(widths[i], c.count) }
        }
        widths = widths.map { min($0, maxCellWidth) }
        func line(_ values: [String]) -> String {
            values.enumerated().map { i, v in
                let w = i < widths.count ? widths[i] : v.count
                return i == values.count - 1 ? v : v.padding(toLength: max(w, v.count), withPad: " ", startingAt: 0)
            }.joined(separator: " | ")
        }
        var out = line(headers) + "\n" + widths.map { String(repeating: "-", count: max($0, 1)) }.joined(separator: "-+-")
        var size = out.utf8.count
        for (n, row) in cells.enumerated() {
            let l = line(row)
            size += l.utf8.count + 1
            if size > maxChars {
                out += "\n… output cut after \(n) of \(rows.count) rows (size limit)"
                break
            }
            out += "\n" + l
        }
        return out
    }

    static func csv(headers: [String], rows: [[String?]], maxChars: Int = 60_000) -> String {
        func field(_ v: String?) -> String {
            guard let v else { return "" }
            if v.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
                return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return v
        }
        var out = headers.map(field).joined(separator: ",")
        var size = out.utf8.count
        for (n, row) in rows.enumerated() {
            let l = row.map(field).joined(separator: ",")
            size += l.utf8.count + 1
            if size > maxChars {
                out += "\n# output cut after \(n) of \(rows.count) rows (size limit)"
                break
            }
            out += "\n" + l
        }
        return out
    }

    static func cell(_ v: String?) -> String {
        guard let v else { return "NULL" }
        var s = v.replacingOccurrences(of: "\r\n", with: "\\n").replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: " ")
        if s.count > maxCellWidth { s = String(s.prefix(maxCellWidth - 1)) + "…" }
        return s
    }

    static func result(_ r: QueryResult, maxRows: Int, format: String) -> String {
        guard r.hasRows else {
            if let a = r.affectedRows { return "\(r.commandTag.isEmpty ? "OK" : r.commandTag) — \(a) row\(a == 1 ? "" : "s") affected" }
            return r.commandTag.isEmpty ? "OK (no result set)" : r.commandTag
        }
        let headers = r.columns.map(\.name)
        let body = format == "csv" ? csv(headers: headers, rows: r.rows) : render(headers: headers, rows: r.rows)
        var footer = "\(r.rows.count) row\(r.rows.count == 1 ? "" : "s") in \(QueryResult.format(r.duration))"
        if r.isTruncated { footer += " — truncated at max_rows=\(maxRows); add a LIMIT/WHERE or raise max_rows to see more" }
        var out = body + "\n\n" + footer
        if !r.notices.isEmpty { out += "\nNotices:\n" + r.notices.joined(separator: "\n") }
        return out
    }
}
