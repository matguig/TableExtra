import Foundation
import MTPCore

/// A PostgreSQL client binary found on disk (pg_dump, pg_restore, psql).
public struct PGTool: Identifiable, Hashable, Sendable {
    public var name: String
    public var url: URL
    /// "17.2"
    public var version: String
    public var major: Int

    public var id: String { url.path }
    public var displayName: String { "\(name) \(version) — \((url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)" }
}

public enum PGToolLocator {
    /// UserDefaults key holding a directory searched before the defaults.
    public static let directoryDefaultsKey = "pgDumpDirectory"

    public static func searchDirectories(defaults: UserDefaults = .standard) -> [String] {
        var dirs: [String] = []
        if let custom = defaults.string(forKey: directoryDefaultsKey), !custom.isEmpty {
            dirs.append((custom as NSString).expandingTildeInPath)
        }
        dirs += ["/opt/homebrew/opt/libpq/bin", "/opt/homebrew/bin", "/usr/local/opt/libpq/bin", "/usr/local/bin"]
        let app = "/Applications/Postgres.app/Contents/Versions"
        dirs.append("\(app)/latest/bin")
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: app) {
            let sorted = versions.filter { $0 != "latest" }.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            dirs += sorted.map { "\(app)/\($0)/bin" }
        }
        var seen: Set<String> = []
        return dirs.filter { seen.insert(($0 as NSString).resolvingSymlinksInPath).inserted }
    }

    /// Every copy of `tool` in search order, with its version.
    public static func candidates(_ tool: String, defaults: UserDefaults = .standard) -> [PGTool] {
        var out: [PGTool] = []
        var seenTargets: Set<String> = []
        for dir in searchDirectories(defaults: defaults) {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(tool)
            guard FileManager.default.isExecutableFile(atPath: url.path) else { continue }
            guard seenTargets.insert(url.resolvingSymlinksInPath().path).inserted else { continue }
            guard let v = version(of: url) else { continue }
            out.append(PGTool(name: tool, url: url, version: v.0, major: v.1))
        }
        return out
    }

    /// The custom directory wins; then the server's own major version (newer tools can emit settings an older
    /// server rejects, e.g. pg_dump 17.0–17.2 writes `SET transaction_timeout`); then the oldest newer copy; else the first found.
    public static func preferred(_ tool: String, serverMajor: Int?, among list: [PGTool], defaults: UserDefaults = .standard) -> PGTool? {
        if let custom = defaults.string(forKey: directoryDefaultsKey), !custom.isEmpty,
           let t = list.first(where: { $0.url.deletingLastPathComponent().path == (custom as NSString).expandingTildeInPath }) {
            return t
        }
        if let serverMajor {
            if let t = list.first(where: { $0.major == serverMajor }) { return t }
            if let t = list.filter({ $0.major > serverMajor }).min(by: { $0.major < $1.major }) { return t }
        }
        return list.first
    }

    /// Runs `tool --version` ("pg_dump (PostgreSQL) 17.2").
    public static func version(of url: URL) -> (String, Int)? {
        let p = Process()
        p.executableURL = url
        p.arguments = ["--version"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return parseVersion(String(decoding: data, as: UTF8.self))
    }

    static func parseVersion(_ text: String) -> (String, Int)? {
        guard let r = text.range(of: "[0-9]+(\\.[0-9]+)*", options: .regularExpression) else { return nil }
        let v = String(text[r])
        guard let major = Int(v.split(separator: ".").first ?? "") else { return nil }
        return (v, major)
    }

    /// 140015 → 14, 90624 → 9.
    public static func serverMajor(versionNum: Int) -> Int { versionNum / 10_000 }
}

/// libpq settings for the command-line tools: arguments for host/port/user/db, secrets and TLS via environment.
public struct PGConnectionTarget: Sendable {
    public var host: String
    public var port: Int
    public var user: String
    public var database: String
    public var password: String?
    public var sslMode: SSLMode
    public var extraOptions: [String: String]

    public init(config: ConnectionConfig, password: String?, database: String? = nil, host: String? = nil, port: Int? = nil) {
        self.host = host ?? (config.host.isEmpty ? "127.0.0.1" : config.host)
        self.port = port ?? config.effectivePort
        self.user = config.user
        self.database = database ?? (config.database.isEmpty ? (config.user.isEmpty ? "postgres" : config.user) : config.database)
        self.password = password
        self.sslMode = config.sslMode
        self.extraOptions = config.extraOptions
    }

    /// Connection arguments (never the password). `--no-password` avoids a hidden prompt hanging the process.
    public func arguments(databaseFlag: String = "--dbname") -> [String] {
        var a = ["--host", host, "--port", String(port)]
        if !user.isEmpty { a += ["--username", user] }
        a += ["\(databaseFlag)=\(database)", "--no-password"]
        return a
    }

    static let envKeys: [String: String] = [
        "sslrootcert": "PGSSLROOTCERT", "sslcert": "PGSSLCERT", "sslkey": "PGSSLKEY", "sslcrl": "PGSSLCRL",
        "options": "PGOPTIONS", "connect_timeout": "PGCONNECT_TIMEOUT", "application_name": "PGAPPNAME",
        "target_session_attrs": "PGTARGETSESSIONATTRS", "sslnegotiation": "PGSSLNEGOTIATION", "gssencmode": "PGGSSENCMODE",
    ]

    public func environment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        // Drop the user's own PG* variables so they cannot redirect the tool to another server.
        var env = base.filter { !$0.key.hasPrefix("PG") }
        env["PGSSLMODE"] = sslMode.rawValue
        env["PGAPPNAME"] = "TableExtra"
        env["PGCONNECT_TIMEOUT"] = "10"
        if let password, !password.isEmpty { env["PGPASSWORD"] = password }
        for (k, v) in extraOptions { if let e = Self.envKeys[k] { env[e] = v } }
        return env
    }
}

/// pg_dump settings.
public struct PGDumpOptions: Hashable, Sendable {
    public enum Format: String, CaseIterable, Identifiable, Sendable {
        case custom, plain, directory, tar
        public var id: String { rawValue }
        public var flag: String {
            switch self {
            case .custom: return "c"
            case .plain: return "p"
            case .directory: return "d"
            case .tar: return "t"
            }
        }
        public var displayName: String {
            switch self {
            case .custom: return "Custom (.dump)"
            case .plain: return "Plain SQL"
            case .directory: return "Directory"
            case .tar: return "Tar"
            }
        }
        public var fileExtension: String {
            switch self {
            case .custom: return "dump"
            case .plain: return "sql"
            case .directory: return ""
            case .tar: return "tar"
            }
        }
        public var supportsCompression: Bool { self != .tar }
    }

    public enum Content: String, CaseIterable, Identifiable, Sendable {
        case all = "Schema and data"
        case schemaOnly = "Schema only"
        case dataOnly = "Data only"
        public var id: String { rawValue }
    }

    public var format: Format = .custom
    public var content: Content = .all
    public var schemas: [String] = []
    /// "schema.table" pairs to include (empty = everything).
    public var tables: [PGTableRef] = []
    public var excludeTables: [PGTableRef] = []
    public var noOwner = false
    public var noPrivileges = false
    /// Plain format only: DROP … IF EXISTS before CREATE.
    public var clean = false
    /// 0–9; nil keeps pg_dump's default.
    public var compression: Int?
    /// Directory format only.
    public var jobs = 1

    public init() {}

    public func arguments(output: String) -> [String] {
        var a = ["--format=\(format.flag)", "--verbose", "--file=\(output)"]
        switch content {
        case .all: break
        case .schemaOnly: a.append("--schema-only")
        case .dataOnly: a.append("--data-only")
        }
        for s in schemas { a += ["--schema", PGPattern.quote(s)] }
        for t in tables { a += ["--table", t.pattern] }
        for t in excludeTables { a += ["--exclude-table", t.pattern] }
        if noOwner { a.append("--no-owner") }
        if noPrivileges { a.append("--no-privileges") }
        if clean && format == .plain && content != .dataOnly { a += ["--clean", "--if-exists"] }
        if let compression, format.supportsCompression { a.append("--compress=\(max(0, min(9, compression)))") }
        if format == .directory && jobs > 1 { a.append("--jobs=\(jobs)") }
        return a
    }
}

public struct PGTableRef: Hashable, Sendable, Identifiable, Comparable {
    public var schema: String
    public var name: String
    public init(schema: String, name: String) {
        self.schema = schema
        self.name = name
    }
    public var id: String { "\(schema).\(name)" }
    /// Exact-match psql pattern: "schema"."table".
    public var pattern: String { PGPattern.quote(schema) + "." + PGPattern.quote(name) }
    public static func < (a: PGTableRef, b: PGTableRef) -> Bool { (a.schema, a.name) < (b.schema, b.name) }
}

enum PGPattern {
    /// Inside double quotes psql patterns match literally (wildcards included); quotes are doubled.
    static func quote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
}

/// pg_restore / psql settings.
public struct PGRestoreOptions: Hashable, Sendable {
    public var clean = false
    public var noOwner = false
    public var noPrivileges = false
    public var singleTransaction = false
    public var jobs = 1
    public var content: PGDumpOptions.Content = .all
    /// pg_restore: stop at the first error. psql: ON_ERROR_STOP=1.
    public var stopOnError = true

    public init() {}

    public func pgRestoreArguments(input: String) -> [String] {
        var a = ["--verbose"]
        switch content {
        case .all: break
        case .schemaOnly: a.append("--schema-only")
        case .dataOnly: a.append("--data-only")
        }
        if clean && content != .dataOnly { a += ["--clean", "--if-exists"] }
        if noOwner { a.append("--no-owner") }
        if noPrivileges { a.append("--no-privileges") }
        // --single-transaction cannot be combined with parallel jobs.
        if singleTransaction { a.append("--single-transaction") } else if jobs > 1 { a.append("--jobs=\(jobs)") }
        if stopOnError { a.append("--exit-on-error") }
        a.append(input)
        return a
    }

    /// psql reads the script from `input`, or from stdin when nil (compressed scripts are piped through gunzip).
    public func psqlArguments(input: String?) -> [String] {
        var a = ["--echo-errors", "--set=ON_ERROR_STOP=\(stopOnError ? 1 : 0)"]
        if singleTransaction { a.append("--single-transaction") }
        if let input { a += ["--file=\(input)"] }
        return a
    }
}

/// What a backup file is, judged from its content.
public enum BackupFileFormat: String, Sendable {
    case custom, tar, directory, plain, gzipPlain

    public var displayName: String {
        switch self {
        case .custom: return "pg_dump custom archive"
        case .tar: return "pg_dump tar archive"
        case .directory: return "pg_dump directory archive"
        case .plain: return "Plain SQL script"
        case .gzipPlain: return "Gzip-compressed SQL script"
        }
    }

    public var usesPgRestore: Bool { self == .custom || self == .tar || self == .directory }

    public static func detect(_ url: URL) -> BackupFileFormat {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { return .directory }
        guard let h = try? FileHandle(forReadingFrom: url) else { return .plain }
        defer { try? h.close() }
        let head = [UInt8]((try? h.read(upToCount: 512)) ?? Data())
        if head.starts(with: Array("PGDMP".utf8)) { return .custom }
        if head.count >= 262, Array(head[257..<262]) == Array("ustar".utf8) { return .tar }
        if head.starts(with: [0x1F, 0x8B]) { return .gzipPlain }
        return .plain
    }
}

public enum BackupNaming {
    /// <connection>-<db>-<yyyyMMdd-HHmm>.<ext>
    public static func defaultURL(connection: ConnectionConfig, database: String, fileExtension: String, date: Date = Date(),
                                  directory: URL = AppPaths.backupsDirectory) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmm"
        let base = [sanitize(connection.name.isEmpty ? "connection" : connection.name), sanitize(database), f.string(from: date)]
            .filter { !$0.isEmpty }.joined(separator: "-")
        let url = directory.appendingPathComponent(base)
        return fileExtension.isEmpty ? url : url.appendingPathExtension(fileExtension)
    }

    static func sanitize(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let mapped = s.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
        return mapped.replacingOccurrences(of: "__+", with: "_", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }
}
