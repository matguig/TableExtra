import Foundation
import MTPCore

/// Direction is always "what must happen to TARGET so that it looks like SOURCE":
/// `added` exists only in the source, `removed` only in the target.
public enum DiffChange: String, Sendable, Codable, CaseIterable, Hashable {
    case added, removed, changed

    public var symbol: String {
        switch self {
        case .added: return "+"
        case .removed: return "−"
        case .changed: return "~"
        }
    }
}

public struct ColumnDiff: Hashable, Sendable, Identifiable {
    public var name: String
    public var change: DiffChange
    public var source: ColumnDef?
    public var target: ColumnDef?
    public var typeChanged = false
    public var nullabilityChanged = false
    public var defaultChanged = false
    public var identityChanged = false
    public var generatedChanged = false

    public var id: String { name }

    /// "type text → character(2), NOT NULL, default now()" style summary.
    public var summary: String {
        switch change {
        case .added: return "\(source?.dataType ?? "")\(source?.isNullable == false ? " NOT NULL" : "")"
        case .removed: return target?.dataType ?? ""
        case .changed:
            guard let s = source, let t = target else { return "" }
            var parts: [String] = []
            if typeChanged { parts.append("type \(t.dataType) → \(s.dataType)") }
            if nullabilityChanged { parts.append(s.isNullable ? "nullable" : "NOT NULL") }
            if defaultChanged { parts.append("default \(t.defaultValue ?? "none") → \(s.defaultValue ?? "none")") }
            if identityChanged { parts.append(s.isIdentity ? "identity" : "no identity") }
            if generatedChanged { parts.append(s.isGenerated ? "generated" : "not generated") }
            return parts.joined(separator: ", ")
        }
    }
}

public struct IndexDiff: Hashable, Sendable, Identifiable {
    public var name: String
    public var change: DiffChange
    public var source: IndexDef?
    public var target: IndexDef?
    /// Target index with the same definition under another name.
    public var renamedFrom: String?

    public var id: String { name }
}

public struct ConstraintDiff: Hashable, Sendable, Identifiable {
    public var name: String
    public var change: DiffChange
    public var kind: ConstraintKind
    public var source: ConstraintDef?
    public var target: ConstraintDef?
    public var renamedFrom: String?

    public var id: String { name }
}

public struct TableDiff: Hashable, Sendable, Identifiable {
    public var name: String
    public var change: DiffChange
    public var source: TableDetails?
    public var target: TableDetails?
    public var columns: [ColumnDiff] = []
    public var indexes: [IndexDiff] = []
    public var constraints: [ConstraintDiff] = []

    public var id: String { name }
    public var hasChanges: Bool { change != .changed || !columns.isEmpty || !indexes.isEmpty || !constraints.isEmpty }

    /// "2 columns, 1 index" for list rows.
    public var summary: String {
        switch change {
        case .added: return "\(source?.columns.count ?? 0) columns"
        case .removed: return "\(target?.columns.count ?? 0) columns"
        case .changed:
            var parts: [String] = []
            if !columns.isEmpty { parts.append("\(columns.count) column\(columns.count == 1 ? "" : "s")") }
            if !indexes.isEmpty { parts.append("\(indexes.count) index\(indexes.count == 1 ? "" : "es")") }
            if !constraints.isEmpty { parts.append("\(constraints.count) constraint\(constraints.count == 1 ? "" : "s")") }
            return parts.joined(separator: ", ")
        }
    }
}

public struct EnumDiff: Hashable, Sendable, Identifiable {
    public var name: String
    public var change: DiffChange
    public var source: EnumTypeDef?
    public var target: EnumTypeDef?
    public var addedValues: [String] = []
    public var removedValues: [String] = []
    /// Same labels in another order (PostgreSQL cannot reorder in place).
    public var orderChanged = false

    public var id: String { name }

    public var summary: String {
        switch change {
        case .added: return (source?.values ?? []).joined(separator: ", ")
        case .removed: return (target?.values ?? []).joined(separator: ", ")
        case .changed:
            var parts: [String] = []
            if !addedValues.isEmpty { parts.append("+ " + addedValues.joined(separator: ", ")) }
            if !removedValues.isEmpty { parts.append("− " + removedValues.joined(separator: ", ")) }
            if orderChanged { parts.append("order changed") }
            return parts.joined(separator: "  ")
        }
    }
}

public struct ViewDiff: Hashable, Sendable, Identifiable {
    public var name: String
    public var change: DiffChange
    public var kind: DBObjectKind
    public var source: ViewDef?
    public var target: ViewDef?
    /// Source details (columns, indexes of materialized views).
    public var sourceDetails: TableDetails?

    public var id: String { name }
}

public struct SchemaDiffResult: Hashable, Sendable {
    public var sourceSchema: String
    public var targetSchema: String
    public var tables: [TableDiff]
    public var enums: [EnumDiff]
    public var views: [ViewDiff]
    /// Names of tables present on both sides with no difference.
    public var unchangedTables: [String]
    /// Enum type names of the source schema (used to retarget column types).
    public var sourceEnumNames: Set<String>

    public init(sourceSchema: String, targetSchema: String, tables: [TableDiff] = [], enums: [EnumDiff] = [], views: [ViewDiff] = [],
                unchangedTables: [String] = [], sourceEnumNames: Set<String> = []) {
        self.sourceSchema = sourceSchema
        self.targetSchema = targetSchema
        self.tables = tables
        self.enums = enums
        self.views = views
        self.unchangedTables = unchangedTables
        self.sourceEnumNames = sourceEnumNames
    }

    public var isEmpty: Bool { tables.isEmpty && enums.isEmpty && views.isEmpty }
    public var changeCount: Int { tables.count + enums.count + views.count }

    public func table(_ name: String) -> TableDiff? { tables.first { $0.name == name } }
}

public enum SchemaDiff {
    /// Compares tables (views are ignored here; use the snapshot overload for views and enums).
    public static func compare(source: [TableDetails], target: [TableDetails]) -> SchemaDiffResult {
        let s = SchemaSnapshot(schema: source.first?.object.schema ?? target.first?.object.schema ?? "", tables: source)
        let t = SchemaSnapshot(schema: target.first?.object.schema ?? s.schema, tables: target)
        return compare(source: s, target: t)
    }

    public static func compare(source: SchemaSnapshot, target: SchemaSnapshot) -> SchemaDiffResult {
        let strip: Set<String> = [source.schema, target.schema]
        let tableKinds: Set<DBObjectKind> = [.table]
        let srcTables = Dictionary(source.tables.filter { tableKinds.contains($0.object.kind) }.map { ($0.object.name, $0) }, uniquingKeysWith: { a, _ in a })
        let dstTables = Dictionary(target.tables.filter { tableKinds.contains($0.object.kind) }.map { ($0.object.name, $0) }, uniquingKeysWith: { a, _ in a })

        var tables: [TableDiff] = []
        var unchanged: [String] = []
        for name in Set(srcTables.keys).union(dstTables.keys).sorted() {
            switch (srcTables[name], dstTables[name]) {
            case let (s?, nil):
                tables.append(TableDiff(name: name, change: .added, source: s, target: nil))
            case let (nil, t?):
                tables.append(TableDiff(name: name, change: .removed, source: nil, target: t))
            case let (s?, t?):
                let d = compareTable(source: s, target: t, strip: strip)
                if d.hasChanges { tables.append(d) } else { unchanged.append(name) }
            default:
                break
            }
        }

        var enumNames = Set(source.enums.map(\.name))
        for t in source.tables {
            for c in t.columns where c.enumValues != nil { enumNames.insert(c.udtName) }
        }

        return SchemaDiffResult(sourceSchema: source.schema, targetSchema: target.schema, tables: tables,
                                enums: compareEnums(source: source.enums, target: target.enums),
                                views: compareViews(source: source, target: target, strip: strip),
                                unchangedTables: unchanged, sourceEnumNames: enumNames)
    }

    // MARK: Tables

    static func compareTable(source s: TableDetails, target t: TableDetails, strip: Set<String>) -> TableDiff {
        var diff = TableDiff(name: s.object.name, change: .changed, source: s, target: t)

        let tCols = Dictionary(t.columns.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let sNames = Set(s.columns.map(\.name))
        for sc in s.columns {
            guard let tc = tCols[sc.name] else {
                diff.columns.append(ColumnDiff(name: sc.name, change: .added, source: sc, target: nil))
                continue
            }
            var c = ColumnDiff(name: sc.name, change: .changed, source: sc, target: tc)
            c.typeChanged = SQLNormalizer.normalize(sc.dataType, stripping: strip) != SQLNormalizer.normalize(tc.dataType, stripping: strip)
            c.nullabilityChanged = sc.isNullable != tc.isNullable
            c.defaultChanged = normalizedDefault(sc, strip) != normalizedDefault(tc, strip)
            c.identityChanged = sc.isIdentity != tc.isIdentity
            c.generatedChanged = sc.isGenerated != tc.isGenerated
            if c.typeChanged || c.nullabilityChanged || c.defaultChanged || c.identityChanged || c.generatedChanged {
                diff.columns.append(c)
            }
        }
        for tc in t.columns where !sNames.contains(tc.name) {
            diff.columns.append(ColumnDiff(name: tc.name, change: .removed, source: nil, target: tc))
        }

        diff.constraints = compareConstraints(source: s.constraints, target: t.constraints, strip: strip)
        diff.indexes = compareIndexes(source: plainIndexes(s), target: plainIndexes(t), strip: strip)
        return diff
    }

    static func normalizedDefault(_ c: ColumnDef, _ strip: Set<String>) -> String? {
        guard !c.isIdentity, let d = c.defaultValue else { return nil }
        return SQLNormalizer.normalize(d, stripping: strip)
    }

    /// Indexes that do not back a constraint (those are compared as constraints).
    static func plainIndexes(_ t: TableDetails) -> [IndexDef] {
        let constraintNames = Set(t.constraints.filter { $0.kind != .foreignKey && $0.kind != .check }.map(\.name))
        return t.indexes.filter { !$0.isPrimary && !constraintNames.contains($0.name) }
    }

    static func compareIndexes(source: [IndexDef], target: [IndexDef], strip: Set<String>) -> [IndexDiff] {
        var out: [IndexDiff] = []
        let tByName = Dictionary(target.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var unmatchedSource: [IndexDef] = []
        var matchedTarget = Set<String>()
        for si in source {
            if let ti = tByName[si.name] {
                matchedTarget.insert(ti.name)
                if SQLNormalizer.indexKey(si, stripping: strip) != SQLNormalizer.indexKey(ti, stripping: strip) {
                    out.append(IndexDiff(name: si.name, change: .changed, source: si, target: ti))
                }
            } else {
                unmatchedSource.append(si)
            }
        }
        var unmatchedTarget = target.filter { !matchedTarget.contains($0.name) }
        for si in unmatchedSource {
            let key = SQLNormalizer.indexKey(si, stripping: strip)
            if let i = unmatchedTarget.firstIndex(where: { SQLNormalizer.indexKey($0, stripping: strip) == key }) {
                out.append(IndexDiff(name: si.name, change: .changed, source: si, target: unmatchedTarget[i], renamedFrom: unmatchedTarget[i].name))
                unmatchedTarget.remove(at: i)
            } else {
                out.append(IndexDiff(name: si.name, change: .added, source: si, target: nil))
            }
        }
        for ti in unmatchedTarget {
            out.append(IndexDiff(name: ti.name, change: .removed, source: nil, target: ti))
        }
        return out.sorted { $0.name < $1.name }
    }

    static func compareConstraints(source: [ConstraintDef], target: [ConstraintDef], strip: Set<String>) -> [ConstraintDiff] {
        func key(_ c: ConstraintDef) -> String { c.kind.rawValue + "|" + SQLNormalizer.normalize(c.definition, stripping: strip) }
        var out: [ConstraintDiff] = []
        let tByName = Dictionary(target.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var unmatchedSource: [ConstraintDef] = []
        var matchedTarget = Set<String>()
        for sc in source {
            if let tc = tByName[sc.name] {
                matchedTarget.insert(tc.name)
                if key(sc) != key(tc) {
                    out.append(ConstraintDiff(name: sc.name, change: .changed, kind: sc.kind, source: sc, target: tc))
                }
            } else {
                unmatchedSource.append(sc)
            }
        }
        var unmatchedTarget = target.filter { !matchedTarget.contains($0.name) }
        for sc in unmatchedSource {
            if let i = unmatchedTarget.firstIndex(where: { key($0) == key(sc) }) {
                out.append(ConstraintDiff(name: sc.name, change: .changed, kind: sc.kind, source: sc, target: unmatchedTarget[i],
                                          renamedFrom: unmatchedTarget[i].name))
                unmatchedTarget.remove(at: i)
            } else {
                out.append(ConstraintDiff(name: sc.name, change: .added, kind: sc.kind, source: sc, target: nil))
            }
        }
        for tc in unmatchedTarget {
            out.append(ConstraintDiff(name: tc.name, change: .removed, kind: tc.kind, source: nil, target: tc))
        }
        return out.sorted { $0.name < $1.name }
    }

    // MARK: Enums & views

    static func compareEnums(source: [EnumTypeDef], target: [EnumTypeDef]) -> [EnumDiff] {
        let s = Dictionary(source.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let t = Dictionary(target.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [EnumDiff] = []
        for name in Set(s.keys).union(t.keys).sorted() {
            switch (s[name], t[name]) {
            case let (se?, nil): out.append(EnumDiff(name: name, change: .added, source: se, target: nil))
            case let (nil, te?): out.append(EnumDiff(name: name, change: .removed, source: nil, target: te))
            case let (se?, te?):
                guard se.values != te.values else { continue }
                var d = EnumDiff(name: name, change: .changed, source: se, target: te)
                d.addedValues = se.values.filter { !te.values.contains($0) }
                d.removedValues = te.values.filter { !se.values.contains($0) }
                let common = se.values.filter { te.values.contains($0) }
                d.orderChanged = common != te.values.filter { se.values.contains($0) }
                out.append(d)
            default: break
            }
        }
        return out
    }

    static func compareViews(source: SchemaSnapshot, target: SchemaSnapshot, strip: Set<String>) -> [ViewDiff] {
        let s = Dictionary(source.views.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let t = Dictionary(target.views.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let details = Dictionary(source.tables.map { ($0.object.name, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [ViewDiff] = []
        for name in Set(s.keys).union(t.keys).sorted() {
            switch (s[name], t[name]) {
            case let (sv?, nil):
                out.append(ViewDiff(name: name, change: .added, kind: sv.kind, source: sv, target: nil, sourceDetails: details[name]))
            case let (nil, tv?):
                out.append(ViewDiff(name: name, change: .removed, kind: tv.kind, source: nil, target: tv))
            case let (sv?, tv?):
                let same = sv.kind == tv.kind
                    && SQLNormalizer.normalize(sv.definition, stripping: strip) == SQLNormalizer.normalize(tv.definition, stripping: strip)
                if !same {
                    out.append(ViewDiff(name: name, change: .changed, kind: sv.kind, source: sv, target: tv, sourceDetails: details[name]))
                }
            default: break
            }
        }
        return out
    }
}
