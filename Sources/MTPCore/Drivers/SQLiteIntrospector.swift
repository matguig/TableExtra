import Foundation

public struct SQLiteIntrospector: SchemaIntrospector {
    public let client: DBClient
    private var dialect: SQLDialect { client.dialect }

    public init(client: DBClient) { self.client = client }

    public func databases() async throws -> [String] {
        let r = try await client.query("PRAGMA database_list")
        return r.rows.compactMap { $0[1] }
    }

    public func schemas(includeSystem: Bool = false) async throws -> [String] {
        try await databases().filter { includeSystem || $0 != "temp" }
    }

    public func defaultSchema() async throws -> String { "main" }

    private func master(_ schema: String) -> String { "\(dialect.quoteIdent(schema)).sqlite_master" }

    public func objects(in schema: String) async throws -> [DBObject] {
        let r = try await client.query("SELECT name, type FROM \(master(schema)) WHERE type IN ('table','view') AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' ORDER BY name")
        var out: [DBObject] = []
        for row in r.rows {
            let name = row[0] ?? ""
            let kind: DBObjectKind = row[1] == "view" ? .view : .table
            out.append(DBObject(schema: schema, name: name, kind: kind))
        }
        return out
    }

    public func tableDetails(schema: String, name: String) async throws -> TableDetails {
        let s = dialect.quoteIdent(schema)
        let t = dialect.quoteIdent(name)
        let typeRow = try await client.query("SELECT type, sql FROM \(master(schema)) WHERE name = ?1", [name])
        guard let meta = typeRow.rows.first else { throw DatabaseError("Table \(name) does not exist") }
        let kind: DBObjectKind = meta[0] == "view" ? .view : .table
        let createSQL = meta[1] ?? ""

        let info = try await client.query("PRAGMA \(s).table_xinfo(\(t))")
        let fkRows = try await client.query("PRAGMA \(s).foreign_key_list(\(t))")
        var fks: [Int: ForeignKeyRef] = [:]
        for r in fkRows.rows {
            let id = Int(r[0] ?? "0") ?? 0
            var fk = fks[id] ?? ForeignKeyRef(constraintName: "fk_\(name)_\(id)", columns: [], refSchema: schema, refTable: r[2] ?? "",
                                             refColumns: [], onUpdate: r[5], onDelete: r[6])
            fk.columns.append(r[3] ?? "")
            fk.refColumns.append(r[4] ?? "")
            fks[id] = fk
        }
        let autoincrement = createSQL.range(of: "AUTOINCREMENT", options: .caseInsensitive) != nil

        var pkCols: [(Int, String)] = []
        var columns: [ColumnDef] = info.rows.map { r in
            let colName = r[1] ?? ""
            let type = r[2] ?? ""
            let pkIndex = Int(r[5] ?? "0") ?? 0
            if pkIndex > 0 { pkCols.append((pkIndex, colName)) }
            let hidden = Int(r[6] ?? "0") ?? 0
            return ColumnDef(name: colName, dataType: type.isEmpty ? "ANY" : type, udtName: type.lowercased(),
                             isNullable: r[3] != "1" && pkIndex == 0, defaultValue: r[4], isPrimaryKey: pkIndex > 0,
                             isIdentity: pkIndex > 0 && type.uppercased() == "INTEGER" && (autoincrement || true),
                             ordinal: (Int(r[0] ?? "0") ?? 0) + 1, isGenerated: hidden == 2 || hidden == 3)
        }
        let fkList = fks.keys.sorted().compactMap { fks[$0] }
        for i in columns.indices {
            columns[i].foreignKey = fkList.first { $0.columns.contains(columns[i].name) }
            // Only a single INTEGER PRIMARY KEY is a rowid alias that fills itself.
            if pkCols.count != 1 { columns[i].isIdentity = false }
        }

        var constraints: [ConstraintDef] = []
        let pk = pkCols.sorted { $0.0 < $1.0 }.map(\.1)
        if !pk.isEmpty {
            constraints.append(ConstraintDef(name: "\(name)_pkey", kind: .primaryKey, columns: pk,
                                             definition: "PRIMARY KEY (\(pk.map(dialect.quoteIdent).joined(separator: ", ")))"))
        }
        for fk in fkList {
            var def = "FOREIGN KEY (\(fk.columns.map(dialect.quoteIdent).joined(separator: ", "))) REFERENCES \(dialect.quoteIdent(fk.refTable)) (\(fk.refColumns.map(dialect.quoteIdent).joined(separator: ", ")))"
            if let d = fk.onDelete, d != "NO ACTION" { def += " ON DELETE \(d)" }
            if let u = fk.onUpdate, u != "NO ACTION" { def += " ON UPDATE \(u)" }
            constraints.append(ConstraintDef(name: fk.constraintName, kind: .foreignKey, columns: fk.columns, definition: def, foreignKey: fk))
        }

        var indexes: [IndexDef] = []
        let idxList = try await client.query("PRAGMA \(s).index_list(\(t))")
        for r in idxList.rows {
            let idxName = r[1] ?? ""
            let cols = try await client.query("PRAGMA \(s).index_info(\(dialect.quoteIdent(idxName)))")
            let def = try await client.query("SELECT sql FROM \(master(schema)) WHERE type = 'index' AND name = ?1", [idxName])
            let origin = r[3] ?? "c"
            indexes.append(IndexDef(name: idxName, columns: cols.rows.compactMap { $0[2] }, isUnique: r[2] == "1", isPrimary: origin == "pk",
                                    method: "btree", definition: def.rows.first?[0] ?? "", predicate: r[4] == "1" ? "partial" : nil))
            if origin == "u" {
                let c = cols.rows.compactMap { $0[2] }
                constraints.append(ConstraintDef(name: idxName, kind: .unique, columns: c, definition: "UNIQUE (\(c.map(dialect.quoteIdent).joined(separator: ", ")))"))
            }
        }

        let trg = try await client.query("SELECT name, sql FROM \(master(schema)) WHERE type = 'trigger' AND tbl_name = ?1", [name])
        let triggers = trg.rows.map { r -> TriggerDef in
            let sql = r[1] ?? ""
            let upper = sql.uppercased()
            let timing = upper.contains(" BEFORE ") ? "BEFORE" : (upper.contains(" INSTEAD OF ") ? "INSTEAD OF" : "AFTER")
            let events = ["INSERT", "UPDATE", "DELETE"].filter { upper.contains(" \($0) ") }.joined(separator: " OR ")
            return TriggerDef(name: r[0] ?? "", timing: timing, events: events, definition: sql)
        }

        var count: Int64?
        if kind == .table, let r = try? await client.query("SELECT max(rowid) FROM \(dialect.qualified(schema: schema, name: name))") {
            count = r.rows.first?[0].flatMap { Int64($0) }
        }
        return TableDetails(object: DBObject(schema: schema, name: name, kind: kind, estimatedRows: count),
                            columns: columns, indexes: indexes, constraints: constraints, triggers: triggers)
    }

    public func snapshot(schema: String) async throws -> [TableDetails] {
        var out: [TableDetails] = []
        for o in try await objects(in: schema) where o.kind.hasData {
            out.append(try await tableDetails(schema: schema, name: o.name))
        }
        return out
    }

    public func columnsByTable(schema: String) async throws -> [String: [ColumnDef]] {
        var out: [String: [ColumnDef]] = [:]
        let s = dialect.quoteIdent(schema)
        for o in try await objects(in: schema) {
            let info = try await client.query("PRAGMA \(s).table_info(\(dialect.quoteIdent(o.name)))")
            out[o.name] = info.rows.map { ColumnDef(name: $0[1] ?? "", dataType: $0[2] ?? "", udtName: ($0[2] ?? "").lowercased(), ordinal: (Int($0[0] ?? "0") ?? 0) + 1) }
        }
        return out
    }

    public func ddl(for object: DBObject) async throws -> String {
        let r = try await client.query("SELECT sql FROM \(master(object.schema)) WHERE name = ?1 OR (type = 'index' AND tbl_name = ?1) OR (type = 'trigger' AND tbl_name = ?1) ORDER BY type = 'table' DESC, type = 'view' DESC", [object.name])
        return r.rows.compactMap { $0[0] }.map { $0 + ";" }.joined(separator: "\n\n")
    }

    public func exactCount(schema: String, name: String) async throws -> Int64 {
        let r = try await client.query("SELECT count(*) FROM \(dialect.qualified(schema: schema, name: name))")
        return Int64(r.rows.first?[0] ?? "0") ?? 0
    }
}
