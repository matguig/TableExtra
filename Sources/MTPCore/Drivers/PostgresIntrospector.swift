import Foundation

public struct PostgresIntrospector: SchemaIntrospector {
    public let client: DBClient
    private var dialect: SQLDialect { client.dialect }

    public init(client: DBClient) { self.client = client }

    public func databases() async throws -> [String] {
        let r = try await client.query("SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY datname")
        return r.rows.compactMap { $0[0] }
    }

    public func schemas(includeSystem: Bool = false) async throws -> [String] {
        let filter = includeSystem ? "nspname NOT LIKE 'pg\\_toast%' AND nspname NOT LIKE 'pg\\_temp%'"
            : "nspname NOT LIKE 'pg\\_%' AND nspname <> 'information_schema'"
        let r = try await client.query("SELECT nspname FROM pg_namespace WHERE \(filter) ORDER BY nspname = 'public' DESC, nspname")
        return r.rows.compactMap { $0[0] }
    }

    public func defaultSchema() async throws -> String {
        let r = try await client.query("SELECT coalesce(current_schema(), 'public')")
        return r.rows.first?[0] ?? "public"
    }

    public func objects(in schema: String) async throws -> [DBObject] {
        var out: [DBObject] = []
        let rel = try await client.query("""
            SELECT c.oid, c.relname, c.relkind, obj_description(c.oid, 'pg_class'), c.reltuples::bigint,
                   CASE WHEN c.relkind IN ('r','m','p') THEN pg_total_relation_size(c.oid) END
            FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = $1 AND c.relkind IN ('r','p','v','m','f','S')
            ORDER BY c.relname
            """, [schema])
        for row in rel.rows {
            let kind: DBObjectKind
            switch row[2] {
            case "v": kind = .view
            case "m": kind = .materializedView
            case "f": kind = .foreignTable
            case "S": kind = .sequence
            default: kind = .table
            }
            let est = row[4].flatMap { Int64($0) }
            out.append(DBObject(schema: schema, name: row[1] ?? "", kind: kind, comment: row[3],
                                estimatedRows: est.map { max($0, 0) }, sizeBytes: row[5].flatMap { Int64($0) },
                                oid: row[0].flatMap { UInt32($0) }))
        }
        let funcs = try await client.query("""
            SELECT p.oid, p.proname, p.prokind, pg_get_function_identity_arguments(p.oid), obj_description(p.oid, 'pg_proc')
            FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = $1 AND p.prokind IN ('f','p')
              AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')
            ORDER BY p.proname, 4
            """, [schema])
        for row in funcs.rows {
            let name = row[1] ?? ""
            out.append(DBObject(schema: schema, name: name, kind: row[2] == "p" ? .procedure : .function, comment: row[4],
                                signature: "\(name)(\(row[3] ?? ""))", oid: row[0].flatMap { UInt32($0) }))
        }
        let types = try await client.query("""
            SELECT t.oid, t.typname, obj_description(t.oid, 'pg_type')
            FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
            WHERE n.nspname = $1
              AND (t.typtype IN ('e','d') OR (t.typtype = 'c' AND EXISTS (SELECT 1 FROM pg_class c WHERE c.oid = t.typrelid AND c.relkind = 'c')))
              AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = t.oid AND d.deptype = 'e')
            ORDER BY t.typname
            """, [schema])
        for row in types.rows {
            out.append(DBObject(schema: schema, name: row[1] ?? "", kind: .type, comment: row[2], oid: row[0].flatMap { UInt32($0) }))
        }
        return out
    }

    // MARK: Details

    public func tableDetails(schema: String, name: String) async throws -> TableDetails {
        let reg = dialect.qualified(schema: schema, name: name)
        let all = try await load(filter: "c.oid = $1::regclass", params: [reg])
        guard let t = all.first else { throw DatabaseError("Relation \(schema).\(name) does not exist") }
        return t
    }

    public func snapshot(schema: String) async throws -> [TableDetails] {
        try await load(filter: "n.nspname = $1 AND c.relkind IN ('r','p','v','m','f')", params: [schema])
    }

    private func load(filter: String, params: [String?]) async throws -> [TableDetails] {
        let sep = "E'\\x1f'"
        let rels = try await client.query("""
            SELECT c.oid, n.nspname, c.relname, c.relkind, obj_description(c.oid, 'pg_class'), c.reltuples::bigint
            FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE \(filter) ORDER BY c.relname
            """, params)
        guard !rels.rows.isEmpty else { return [] }

        let cols = try await client.query("""
            SELECT a.attrelid, a.attnum, a.attname, format_type(a.atttypid, a.atttypmod), t.typname, NOT a.attnotnull,
                   pg_get_expr(d.adbin, d.adrelid), a.attidentity <> '', a.attgenerated <> '', col_description(a.attrelid, a.attnum),
                   CASE WHEN t.typtype = 'e' THEN (SELECT string_agg(e.enumlabel, \(sep) ORDER BY e.enumsortorder) FROM pg_enum e WHERE e.enumtypid = t.oid) END
            FROM pg_attribute a
            JOIN pg_class c ON c.oid = a.attrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            JOIN pg_type t ON t.oid = a.atttypid
            LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
            WHERE \(filter) AND a.attnum > 0 AND NOT a.attisdropped
            ORDER BY a.attrelid, a.attnum
            """, params)

        let cons = try await client.query("""
            SELECT con.conrelid, con.conname, con.contype, pg_get_constraintdef(con.oid, true),
                   array_to_string(ARRAY(SELECT a.attname FROM unnest(con.conkey) WITH ORDINALITY k(attnum, ord)
                     JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.attnum ORDER BY k.ord), \(sep)),
                   fn.nspname, fc.relname,
                   array_to_string(ARRAY(SELECT a.attname FROM unnest(con.confkey) WITH ORDINALITY k(attnum, ord)
                     JOIN pg_attribute a ON a.attrelid = con.confrelid AND a.attnum = k.attnum ORDER BY k.ord), \(sep)),
                   con.confupdtype, con.confdeltype
            FROM pg_constraint con
            JOIN pg_class c ON c.oid = con.conrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            LEFT JOIN pg_class fc ON fc.oid = con.confrelid
            LEFT JOIN pg_namespace fn ON fn.oid = fc.relnamespace
            WHERE \(filter)
            ORDER BY con.conrelid, CASE con.contype WHEN 'p' THEN 0 WHEN 'u' THEN 1 WHEN 'f' THEN 2 ELSE 3 END, con.conname
            """, params)

        let idx = try await client.query("""
            SELECT ix.indrelid, i.relname, ix.indisunique, ix.indisprimary, am.amname, pg_get_indexdef(ix.indexrelid),
                   pg_get_expr(ix.indpred, ix.indrelid), pg_relation_size(ix.indexrelid), s.idx_scan,
                   array_to_string(ARRAY(SELECT pg_get_indexdef(ix.indexrelid, k, true) FROM generate_series(1, ix.indnkeyatts) k ORDER BY k), \(sep))
            FROM pg_index ix
            JOIN pg_class i ON i.oid = ix.indexrelid
            JOIN pg_class c ON c.oid = ix.indrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            JOIN pg_am am ON am.oid = i.relam
            LEFT JOIN pg_stat_all_indexes s ON s.indexrelid = ix.indexrelid
            WHERE \(filter)
            ORDER BY ix.indrelid, ix.indisprimary DESC, i.relname
            """, params)

        let trg = try await client.query("""
            SELECT t.tgrelid, t.tgname, pg_get_triggerdef(t.oid, true), t.tgenabled <> 'D',
                   CASE WHEN t.tgtype & 2 = 2 THEN 'BEFORE' WHEN t.tgtype & 64 = 64 THEN 'INSTEAD OF' ELSE 'AFTER' END,
                   concat_ws(' OR ', CASE WHEN t.tgtype & 4 = 4 THEN 'INSERT' END, CASE WHEN t.tgtype & 16 = 16 THEN 'UPDATE' END,
                             CASE WHEN t.tgtype & 8 = 8 THEN 'DELETE' END, CASE WHEN t.tgtype & 32 = 32 THEN 'TRUNCATE' END)
            FROM pg_trigger t
            JOIN pg_class c ON c.oid = t.tgrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE \(filter) AND NOT t.tgisinternal
            ORDER BY t.tgrelid, t.tgname
            """, params)

        func action(_ code: String?) -> String? {
            switch code {
            case "c": return "CASCADE"
            case "n": return "SET NULL"
            case "d": return "SET DEFAULT"
            case "r": return "RESTRICT"
            default: return nil
            }
        }

        var constraintsByRel: [String: [ConstraintDef]] = [:]
        for r in cons.rows {
            let kind: ConstraintKind
            switch r[2] {
            case "p": kind = .primaryKey
            case "f": kind = .foreignKey
            case "u": kind = .unique
            case "x": kind = .exclusion
            default: kind = .check
            }
            let columns = Introspection.split(r[4])
            let fk = kind == .foreignKey
                ? ForeignKeyRef(constraintName: r[1] ?? "", columns: columns, refSchema: r[5] ?? "", refTable: r[6] ?? "",
                                refColumns: Introspection.split(r[7]), onUpdate: action(r[8]), onDelete: action(r[9]))
                : nil
            constraintsByRel[r[0] ?? "", default: []].append(
                ConstraintDef(name: r[1] ?? "", kind: kind, columns: columns, definition: r[3] ?? "", foreignKey: fk))
        }

        var indexesByRel: [String: [IndexDef]] = [:]
        for r in idx.rows {
            indexesByRel[r[0] ?? "", default: []].append(
                IndexDef(name: r[1] ?? "", columns: Introspection.split(r[9]), isUnique: r[2] == "t", isPrimary: r[3] == "t",
                         method: r[4] ?? "btree", definition: r[5] ?? "", predicate: r[6],
                         sizeBytes: r[7].flatMap { Int64($0) }, scans: r[8].flatMap { Int64($0) }))
        }

        var triggersByRel: [String: [TriggerDef]] = [:]
        for r in trg.rows {
            triggersByRel[r[0] ?? "", default: []].append(
                TriggerDef(name: r[1] ?? "", timing: r[4] ?? "", events: r[5] ?? "", definition: r[2] ?? "", isEnabled: r[3] == "t"))
        }

        var columnsByRel: [String: [ColumnDef]] = [:]
        for r in cols.rows {
            let enumValues = r[10].map { Introspection.split($0) }
            columnsByRel[r[0] ?? "", default: []].append(
                ColumnDef(name: r[2] ?? "", dataType: r[3] ?? "", udtName: r[4], isNullable: r[5] == "t", defaultValue: r[6],
                          isIdentity: r[7] == "t", comment: r[9], ordinal: Int(r[1] ?? "0") ?? 0, enumValues: enumValues,
                          isGenerated: r[8] == "t"))
        }

        return rels.rows.map { r in
            let oid = r[0] ?? ""
            let kind: DBObjectKind
            switch r[3] {
            case "v": kind = .view
            case "m": kind = .materializedView
            case "f": kind = .foreignTable
            default: kind = .table
            }
            let constraints = constraintsByRel[oid] ?? []
            let pk = Set(constraints.first { $0.kind == .primaryKey }?.columns ?? [])
            var columns = columnsByRel[oid] ?? []
            for i in columns.indices {
                columns[i].isPrimaryKey = pk.contains(columns[i].name)
                columns[i].foreignKey = constraints.first { $0.kind == .foreignKey && $0.columns.contains(columns[i].name) }?.foreignKey
            }
            let object = DBObject(schema: r[1] ?? "", name: r[2] ?? "", kind: kind, comment: r[4],
                                  estimatedRows: r[5].flatMap { Int64($0) }.map { max($0, 0) }, oid: UInt32(oid))
            return TableDetails(object: object, columns: columns, indexes: indexesByRel[oid] ?? [], constraints: constraints,
                                triggers: triggersByRel[oid] ?? [])
        }
    }

    public func columnsByTable(schema: String) async throws -> [String: [ColumnDef]] {
        let r = try await client.query("""
            SELECT c.relname, a.attname, format_type(a.atttypid, a.atttypmod), t.typname, a.attnum
            FROM pg_attribute a
            JOIN pg_class c ON c.oid = a.attrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            JOIN pg_type t ON t.oid = a.atttypid
            WHERE n.nspname = $1 AND c.relkind IN ('r','p','v','m','f') AND a.attnum > 0 AND NOT a.attisdropped
            ORDER BY c.relname, a.attnum
            """, [schema])
        var out: [String: [ColumnDef]] = [:]
        for row in r.rows {
            out[row[0] ?? "", default: []].append(ColumnDef(name: row[1] ?? "", dataType: row[2] ?? "", udtName: row[3], ordinal: Int(row[4] ?? "0") ?? 0))
        }
        return out
    }

    public func ddl(for object: DBObject) async throws -> String {
        let q = dialect.qualified(schema: object.schema, name: object.name)
        switch object.kind {
        case .table, .foreignTable:
            return DDLWriter.createTable(try await tableDetails(schema: object.schema, name: object.name), dialect: dialect)
        case .view:
            let r = try await client.query("SELECT pg_get_viewdef($1::regclass, true)", [q])
            return "CREATE OR REPLACE VIEW \(q) AS\n\(r.rows.first?[0] ?? "")"
        case .materializedView:
            let r = try await client.query("SELECT pg_get_viewdef($1::regclass, true)", [q])
            var sql = "CREATE MATERIALIZED VIEW \(q) AS\n\(r.rows.first?[0] ?? "")"
            let details = try await tableDetails(schema: object.schema, name: object.name)
            for i in details.indexes { sql += "\n\(i.definition);" }
            return sql
        case .function, .procedure:
            guard let oid = object.oid else { throw DatabaseError("Unknown function") }
            let r = try await client.query("SELECT pg_get_functiondef($1::oid)", [String(oid)])
            return r.rows.first?[0] ?? ""
        case .sequence:
            let r = try await client.query("""
                SELECT data_type, start_value, min_value, max_value, increment_by, cycle, cache_size, last_value
                FROM pg_sequences WHERE schemaname = $1 AND sequencename = $2
                """, [object.schema, object.name])
            guard let s = r.rows.first else { return "" }
            return """
            CREATE SEQUENCE \(q)
              AS \(s[0] ?? "bigint")
              INCREMENT BY \(s[4] ?? "1")
              MINVALUE \(s[2] ?? "1")
              MAXVALUE \(s[3] ?? "")
              START WITH \(s[1] ?? "1")
              CACHE \(s[6] ?? "1")\(s[5] == "t" ? "\n  CYCLE" : "");
            -- last_value: \(s[7] ?? "never used")
            """
        case .type:
            let r = try await client.query("""
                SELECT t.typtype,
                       (SELECT string_agg(quote_literal(e.enumlabel), ', ' ORDER BY e.enumsortorder) FROM pg_enum e WHERE e.enumtypid = t.oid),
                       format_type(t.typbasetype, t.typtypmod),
                       (SELECT string_agg(quote_ident(a.attname) || ' ' || format_type(a.atttypid, a.atttypmod), ', ' ORDER BY a.attnum)
                          FROM pg_attribute a WHERE a.attrelid = t.typrelid AND a.attnum > 0)
                FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace WHERE n.nspname = $1 AND t.typname = $2
                """, [object.schema, object.name])
            guard let t = r.rows.first else { return "" }
            switch t[0] {
            case "e": return "CREATE TYPE \(q) AS ENUM (\(t[1] ?? ""));"
            case "d": return "CREATE DOMAIN \(q) AS \(t[2] ?? "");"
            default: return "CREATE TYPE \(q) AS (\(t[3] ?? ""));"
            }
        }
    }

    public func exactCount(schema: String, name: String) async throws -> Int64 {
        let r = try await client.query("SELECT count(*) FROM \(dialect.qualified(schema: schema, name: name))")
        return Int64(r.rows.first?[0] ?? "0") ?? 0
    }
}
