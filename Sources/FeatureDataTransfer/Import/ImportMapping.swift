import Foundation
import MTPCore

/// Builds the initial column mapping shown by the import sheet.
public enum ImportMapping {
    /// Existing table: file columns matched to table columns by name (exact, then case-insensitive, then snake_case).
    /// Unmatched file columns are skipped; generated columns are never targets.
    public static func mapByName(preview: ImportFilePreview, target: [ColumnDef]) -> [ImportColumn] {
        let usable = target.filter { !$0.isGenerated }
        var taken: Set<String> = []
        return preview.columns.enumerated().map { i, name in
            let inferred = i < preview.inferredTypes.count ? preview.inferredTypes[i] : .text
            let match = usable.first { $0.name == name && !taken.contains($0.name) }
                ?? usable.first { $0.name.caseInsensitiveCompare(name) == .orderedSame && !taken.contains($0.name) }
                ?? usable.first { snakeCase($0.name) == snakeCase(name) && !taken.contains($0.name) }
            if let match {
                taken.insert(match.name)
                return ImportColumn(sourceIndex: i, sourceName: name, inferred: inferred, include: true, target: match.name,
                                    sqlType: match.dataType, targetKind: match.kind)
            }
            return ImportColumn(sourceIndex: i, sourceName: name, inferred: inferred, include: false, target: "", sqlType: "", targetKind: .text)
        }
    }

    /// New table: one column per file column, SQL-friendly names and inferred types.
    public static func newTableColumns(preview: ImportFilePreview, dialect: SQLDialect) -> [ImportColumn] {
        var seen: [String: Int] = [:]
        return preview.columns.enumerated().map { i, name in
            let inferred = i < preview.inferredTypes.count ? preview.inferredTypes[i] : .text
            var target = snakeCase(name)
            if target.isEmpty { target = "column_\(i + 1)" }
            if target.first?.isNumber == true { target = "c_" + target }
            let n = (seen[target] ?? 0) + 1
            seen[target] = n
            if n > 1 { target += "_\(n)" }
            return ImportColumn(sourceIndex: i, sourceName: name, inferred: inferred, include: true, target: target,
                                sqlType: inferred.sqlType(for: dialect), targetKind: inferred.valueKind)
        }
    }

    /// "Order ID" → order_id, "createdAt" → created_at.
    public static func snakeCase(_ s: String) -> String {
        var out = ""
        var prevLower = false
        for ch in s.trimmingCharacters(in: .whitespacesAndNewlines) {
            if ch.isLetter || ch.isNumber {
                if ch.isUppercase && prevLower { out += "_" }
                out += ch.lowercased()
                prevLower = ch.isLowercase || ch.isNumber
            } else {
                if !out.isEmpty && out.last != "_" { out += "_" }
                prevLower = false
            }
        }
        while out.hasSuffix("_") { out.removeLast() }
        return out
    }

    /// Default name for a new table created from a file.
    public static func tableName(for url: URL) -> String {
        let name = snakeCase(url.deletingPathExtension().lastPathComponent)
        if name.isEmpty { return "imported" }
        return name.first?.isNumber == true ? "t_" + name : name
    }
}
