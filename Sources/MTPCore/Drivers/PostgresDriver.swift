import CLibPQ
import Foundation

public final class PostgresDriver: DatabaseDriver {
    public let kind = DriverKind.postgres
    public let dialect = SQLDialect(kind: .postgres)

    private var conn: OpaquePointer?
    private var cancelHandle: OpaquePointer?
    private let cancelLock = NSLock()
    private let params: [(String, String)]
    private var typeNames: [UInt32: String] = [:]
    private var pendingNotices: [String] = []
    private let readOnly: Bool

    public init(config: ConnectionConfig, password: String?, host: String? = nil, port: Int? = nil) throws {
        var p: [(String, String)] = [
            ("host", host ?? (config.host.isEmpty ? "127.0.0.1" : config.host)),
            ("port", String(port ?? config.effectivePort)),
            ("dbname", config.database.isEmpty ? (config.user.isEmpty ? "postgres" : config.user) : config.database),
            ("sslmode", config.sslMode.rawValue),
            ("application_name", "TableExtra"),
            ("connect_timeout", "10"),
            ("client_encoding", "UTF8"),
        ]
        if !config.user.isEmpty { p.append(("user", config.user)) }
        if let password, !password.isEmpty { p.append(("password", password)) }
        for (k, v) in config.extraOptions where !k.isEmpty {
            p.removeAll { $0.0 == k }
            p.append((k, v))
        }
        params = p
        readOnly = config.safety == .readOnly
        try connect()
        if !config.startupSQL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = try execute(config.startupSQL, params: [], maxRows: 0)
        }
    }

    deinit { close() }

    private func connect() throws {
        let keys = params.map { strdup($0.0) }
        let values = params.map { strdup($0.1) }
        defer {
            keys.forEach { free($0) }
            values.forEach { free($0) }
        }
        var keyPtrs: [UnsafePointer<CChar>?] = keys.map { UnsafePointer($0) } + [nil]
        var valuePtrs: [UnsafePointer<CChar>?] = values.map { UnsafePointer($0) } + [nil]
        let c = keyPtrs.withUnsafeMutableBufferPointer { kp in
            valuePtrs.withUnsafeMutableBufferPointer { vp in
                PQconnectdbParams(kp.baseAddress, vp.baseAddress, 0)
            }
        }
        guard let c else { throw DatabaseError("Out of memory while connecting") }
        if PQstatus(c) != CONNECTION_OK {
            let msg = String(cString: PQerrorMessage(c)).trimmingCharacters(in: .whitespacesAndNewlines)
            PQfinish(c)
            throw DatabaseError(msg.isEmpty ? "Connection failed" : msg)
        }
        conn = c
        installNoticeProcessor()
        cancelLock.lock()
        if let old = cancelHandle { PQfreeCancel(old) }
        cancelHandle = PQgetCancel(c)
        cancelLock.unlock()
        if readOnly {
            _ = try execute("SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY", params: [], maxRows: 0)
        }
    }

    private func installNoticeProcessor() {
        guard let conn else { return }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        PQsetNoticeProcessor(conn, { arg, message in
            guard let arg, let message else { return }
            let driver = Unmanaged<PostgresDriver>.fromOpaque(arg).takeUnretainedValue()
            driver.pendingNotices.append(String(cString: message).trimmingCharacters(in: .whitespacesAndNewlines))
        }, ctx)
    }

    public var isAlive: Bool {
        guard let conn else { return false }
        return PQstatus(conn) == CONNECTION_OK
    }

    public var inTransaction: Bool {
        guard let conn else { return false }
        let s = PQtransactionStatus(conn)
        return s == PQTRANS_INTRANS || s == PQTRANS_INERROR || s == PQTRANS_ACTIVE
    }

    public func reconnect() throws {
        if let conn {
            PQreset(conn)
            if PQstatus(conn) == CONNECTION_OK {
                installNoticeProcessor()
                cancelLock.lock()
                if let old = cancelHandle { PQfreeCancel(old) }
                cancelHandle = PQgetCancel(conn)
                cancelLock.unlock()
                return
            }
            PQfinish(conn)
            self.conn = nil
        }
        try connect()
    }

    public func close() {
        cancelLock.lock()
        if let c = cancelHandle { PQfreeCancel(c) }
        cancelHandle = nil
        cancelLock.unlock()
        if let conn { PQfinish(conn) }
        conn = nil
    }

    public func cancel() {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        guard let cancelHandle else { return }
        var buf = [CChar](repeating: 0, count: 256)
        _ = PQcancel(cancelHandle, &buf, Int32(buf.count))
    }

    // MARK: Execution

    public func execute(_ sql: String, params: [String?], maxRows: Int?) throws -> QueryResult {
        if conn == nil || !isAlive { try reconnect() }
        guard let conn else { throw DatabaseError("Not connected") }
        let start = Date()
        pendingNotices.removeAll()
        // Type names must be known before results stream in: running the pg_type lookup in the middle of
        // reading a result consumes the rest of it (a grouped query on an enum column came back with 1 row).
        if !typesLoaded { loadTypes() }

        let sent: Int32
        if params.isEmpty {
            sent = PQsendQuery(conn, sql)
        } else {
            let cValues = params.map { $0.map { strdup($0) } ?? nil }
            defer { cValues.forEach { if let p = $0 { free(p) } } }
            var ptrs: [UnsafePointer<CChar>?] = cValues.map { $0.map { UnsafePointer($0) } }
            sent = ptrs.withUnsafeMutableBufferPointer { buf in
                PQsendQueryParams(conn, sql, Int32(params.count), nil, buf.baseAddress, nil, nil, 0)
            }
        }
        if sent == 0 {
            // A dead socket only shows up here; retry once on a fresh connection.
            if PQstatus(conn) != CONNECTION_OK {
                try reconnect()
                return try execute(sql, params: params, maxRows: maxRows)
            }
            throw DatabaseError(String(cString: PQerrorMessage(conn)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let limit = maxRows.flatMap { $0 > 0 ? $0 : nil }
        if limit != nil { _ = PQsetSingleRowMode(conn) }

        var result = QueryResult(statement: sql)
        var error: DatabaseError?
        var truncated = false
        var sawRows = false

        while let res = PQgetResult(conn) {
            defer { PQclear(res) }
            let status = PQresultStatus(res)
            switch status {
            case PGRES_SINGLE_TUPLE:
                if truncated { continue }
                if !sawRows {
                    result = QueryResult(columns: columns(of: res), statement: sql)
                    sawRows = true
                }
                result.rows.append(contentsOf: rows(of: res))
                if let limit, result.rows.count >= limit {
                    truncated = true
                    cancel()
                }
            case PGRES_TUPLES_OK:
                if truncated { continue }
                if !sawRows || PQntuples(res) > 0 {
                    // Multi-statement scripts: keep the latest row set.
                    let newCols = columns(of: res)
                    if !sawRows || result.columns != newCols {
                        result = QueryResult(columns: newCols, statement: sql)
                    }
                    result.rows.append(contentsOf: rows(of: res))
                    sawRows = true
                }
                result.commandTag = String(cString: PQcmdStatus(res))
            case PGRES_COMMAND_OK:
                if !sawRows {
                    result.commandTag = String(cString: PQcmdStatus(res))
                    let affected = String(cString: PQcmdTuples(res))
                    result.affectedRows = Int(affected)
                }
            case PGRES_EMPTY_QUERY:
                break
            case PGRES_COPY_OUT:
                result = QueryResult(columns: [ResultColumn(name: "copy", typeName: "text")], statement: sql)
                var buffer: UnsafeMutablePointer<CChar>?
                while true {
                    let n = PQgetCopyData(conn, &buffer, 0)
                    if n <= 0 { break }
                    if let b = buffer {
                        let line = String(cString: b).trimmingCharacters(in: .newlines)
                        result.rows.append([line])
                        PQfreemem(b)
                    }
                }
                sawRows = true
            case PGRES_COPY_IN:
                _ = PQputCopyEnd(conn, "COPY FROM STDIN is not supported in the editor; use Import instead")
            default:
                if truncated, errorField(res, "C") == "57014" { continue }
                if error == nil { error = makeError(res) }
            }
        }
        if let error { throw error }
        // A type created after the cache was filled (new enum, domain…): refresh now that the result is read.
        if result.columns.contains(where: { $0.typeName.hasPrefix("oid:") }) {
            loadTypes()
            result.columns = result.columns.map { c in
                guard c.typeName.hasPrefix("oid:") else { return c }
                var c = c
                c.typeName = typeNames[c.typeOID] ?? c.typeName
                if enumOIDs.contains(c.typeOID) { c.kind = .enumeration } else { c.kind = ValueKind.infer(typeName: c.typeName) }
                return c
            }
        }
        result.isTruncated = truncated
        result.duration = Date().timeIntervalSince(start)
        result.notices = pendingNotices
        if sawRows, result.commandTag.isEmpty { result.commandTag = "SELECT \(result.rows.count)" }
        return result
    }

    private func errorField(_ res: OpaquePointer, _ code: Character) -> String? {
        guard let p = PQresultErrorField(res, Int32(code.asciiValue!)) else { return nil }
        return String(cString: p)
    }

    private func makeError(_ res: OpaquePointer) -> DatabaseError {
        let primary = errorField(res, "M") ?? String(cString: PQresultErrorMessage(res)).trimmingCharacters(in: .whitespacesAndNewlines)
        let severity = errorField(res, "S")
        let message = severity.map { "\($0): \(primary)" } ?? primary
        return DatabaseError(message,
                             detail: errorField(res, "D"),
                             hint: errorField(res, "H"),
                             sqlState: errorField(res, "C"),
                             position: errorField(res, "P").flatMap(Int.init))
    }

    private func columns(of res: OpaquePointer) -> [ResultColumn] {
        let n = PQnfields(res)
        guard n > 0 else { return [] }
        return (0..<n).map { i in
            let oid = UInt32(PQftype(res, i))
            return ResultColumn(name: String(cString: PQfname(res, i)),
                                typeName: typeName(oid),
                                typeOID: oid,
                                tableOID: UInt32(PQftable(res, i)),
                                tableColumn: Int(PQftablecol(res, i)),
                                kind: enumOIDs.contains(oid) ? .enumeration : nil)
        }
    }

    private func rows(of res: OpaquePointer) -> [[String?]] {
        let nRows = PQntuples(res)
        let nCols = PQnfields(res)
        guard nRows > 0 else { return [] }
        var out: [[String?]] = []
        out.reserveCapacity(Int(nRows))
        for r in 0..<nRows {
            var row: [String?] = []
            row.reserveCapacity(Int(nCols))
            for c in 0..<nCols {
                if PQgetisnull(res, r, c) == 1 {
                    row.append(nil)
                } else {
                    row.append(String(cString: PQgetvalue(res, r, c)))
                }
            }
            out.append(row)
        }
        return out
    }

    // MARK: Type names

    private var enumOIDs: Set<UInt32> = []
    private var typesLoaded = false

    /// Never queries the server: it runs while a result is being read (see `execute`).
    private func typeName(_ oid: UInt32) -> String {
        if let t = Self.builtinTypes[oid] { return t }
        return typeNames[oid] ?? "oid:\(oid)"
    }

    private func loadTypes() {
        typesLoaded = true
        guard let conn else { return }
        guard let res = PQexec(conn, "SELECT oid, typname, typtype FROM pg_type WHERE typtype IN ('b','e','d','c','r','m') AND typnamespace NOT IN (SELECT oid FROM pg_namespace WHERE nspname = 'pg_toast')") else { return }
        defer { PQclear(res) }
        guard PQresultStatus(res) == PGRES_TUPLES_OK else { return }
        for r in 0..<PQntuples(res) {
            let oid = UInt32(String(cString: PQgetvalue(res, r, 0))) ?? 0
            typeNames[oid] = String(cString: PQgetvalue(res, r, 1))
            if String(cString: PQgetvalue(res, r, 2)) == "e" { enumOIDs.insert(oid) }
        }
    }

    static let builtinTypes: [UInt32: String] = [
        16: "bool", 17: "bytea", 18: "char", 19: "name", 20: "int8", 21: "int2", 23: "int4", 24: "regproc", 25: "text",
        26: "oid", 114: "json", 142: "xml", 600: "point", 650: "cidr", 700: "float4", 701: "float8", 774: "macaddr8",
        790: "money", 829: "macaddr", 869: "inet", 1000: "_bool", 1005: "_int2", 1007: "_int4", 1009: "_text", 1014: "_bpchar",
        1015: "_varchar", 1016: "_int8", 1021: "_float4", 1022: "_float8", 1042: "bpchar", 1043: "varchar", 1082: "date",
        1083: "time", 1114: "timestamp", 1115: "_timestamp", 1182: "_date", 1184: "timestamptz", 1185: "_timestamptz",
        1186: "interval", 1231: "_numeric", 1266: "timetz", 1700: "numeric", 2205: "regclass", 2206: "regtype", 2950: "uuid",
        2951: "_uuid", 3802: "jsonb", 3807: "_jsonb", 199: "_json", 3614: "tsvector", 3615: "tsquery", 2249: "record",
        2278: "void", 705: "unknown", 1560: "bit", 1562: "varbit", 3904: "int4range", 3926: "int8range", 3910: "tstzrange",
        3908: "tsrange", 3912: "daterange", 3906: "numrange", 4089: "regnamespace", 4096: "regrole",
    ]

    // MARK: Server info

    public func serverInfo() throws -> ServerInfo {
        let r = try execute("SELECT version(), current_database(), current_user, current_setting('server_version')", params: [], maxRows: nil)
        let full = r.rows.first?[0] ?? "PostgreSQL"
        let short = r.rows.first?[3] ?? ""
        var product = "PostgreSQL"
        if full.localizedCaseInsensitiveContains("cockroach") { product = "CockroachDB" }
        else if full.localizedCaseInsensitiveContains("redshift") { product = "Redshift" }
        let numeric = conn.map { Int(PQserverVersion($0)) } ?? 0
        return ServerInfo(product: product, version: short.isEmpty ? full : short, numericVersion: numeric,
                          currentDatabase: r.rows.first?[1] ?? "", currentUser: r.rows.first?[2] ?? "")
    }

    public static var libraryVersion: Int { Int(PQlibVersion()) }
}
