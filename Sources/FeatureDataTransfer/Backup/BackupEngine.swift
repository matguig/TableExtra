import Foundation
import MTPCore

/// Builds the processes behind Backup and Restore; the views add logging, timing and cancellation.
public enum BackupEngine {
    public static func pgDump(tool: PGTool, target: PGConnectionTarget, options: PGDumpOptions, output: URL) -> ProcessRunner {
        ProcessRunner(executable: tool.url, arguments: options.arguments(output: output.path) + target.arguments(), environment: target.environment())
    }

    public static func pgRestore(tool: PGTool, target: PGConnectionTarget, options: PGRestoreOptions, input: URL) -> ProcessRunner {
        ProcessRunner(executable: tool.url, arguments: target.arguments() + options.pgRestoreArguments(input: input.path), environment: target.environment())
    }

    /// Plain scripts run through psql. Gzip-compressed ones are decompressed in-process into psql's stdin; so are scripts
    /// for a server older than 17, without pg_dump 17+'s `SET transaction_timeout` line.
    public static func psql(tool: PGTool, target: PGConnectionTarget, options: PGRestoreOptions, input: URL, format: BackupFileFormat,
                            serverMajor: Int? = nil) -> ProcessRunner {
        let gzip = format == .gzipPlain
        let skip = serverMajor.map { $0 > 0 && $0 < 17 } ?? false
        if gzip || skip {
            let feeder = ProcessRunner.StdinFeeder(label: ScriptFeed.label(input, gzip: gzip, skipTransactionTimeout: skip)) { fd in
                try ScriptFeed.stream(input, gzip: gzip, skipTransactionTimeout: skip, to: fd)
            }
            return ProcessRunner(executable: tool.url, arguments: target.arguments() + options.psqlArguments(input: nil), environment: target.environment(),
                                 stdinFeeder: feeder)
        }
        return ProcessRunner(executable: tool.url, arguments: target.arguments() + options.psqlArguments(input: input.path), environment: target.environment())
    }

    /// Runs `body` with the host/port to reach the server, through an SSH tunnel when the connection uses one.
    public static func withEndpoint<T>(_ config: ConnectionConfig, secrets: ConnectionSecrets = ConnectionSecrets(), log: (String) -> Void = { _ in },
                                       _ body: (_ host: String?, _ port: Int?) async throws -> T) async throws -> T {
        guard config.ssh.enabled, config.driver == .postgres else { return try await body(nil, nil) }
        let tunnel = SSHTunnel(ssh: config.ssh, secrets: secrets, remoteHost: config.host.isEmpty ? "127.0.0.1" : config.host, remotePort: config.effectivePort)
        log("Opening SSH tunnel through \(config.ssh.user.isEmpty ? "" : config.ssh.user + "@")\(config.ssh.host)…")
        try await Task.detached { try tunnel.start() }.value
        log("Tunnel ready on 127.0.0.1:\(tunnel.localPort)")
        defer { tunnel.stop() }
        return try await body("127.0.0.1", tunnel.localPort)
    }

    /// SQLite online backup into a new file (VACUUM INTO also defragments the copy).
    public static func sqliteBackup(config: ConnectionConfig, to output: URL) async throws {
        try? FileManager.default.removeItem(at: output)
        let client = DBClient(config: config, secrets: ConnectionSecrets(), label: "backup")
        defer { client.close() }
        _ = try await client.query("VACUUM INTO ?1", [output.path])
    }

    /// Replaces the SQLite file with `backup`, keeping a copy of the current file in the Backups folder.
    /// Returns the safety copy's URL.
    @discardableResult
    public static func sqliteRestore(from backup: URL, over path: String, safetyCopyDirectory: URL = AppPaths.backupsDirectory) throws -> URL? {
        let fm = FileManager.default
        let target = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard try sqliteHeader(backup) else { throw DatabaseError("\(backup.lastPathComponent) is not a SQLite database") }
        var safety: URL?
        if fm.fileExists(atPath: target.path) {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyyMMdd-HHmmss"
            let copy = safetyCopyDirectory.appendingPathComponent("\(target.deletingPathExtension().lastPathComponent)-before-restore-\(f.string(from: Date()))")
                .appendingPathExtension(target.pathExtension.isEmpty ? "sqlite" : target.pathExtension)
            try fm.copyItem(at: target, to: copy)
            safety = copy
        }
        let staging = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).restore-\(UUID().uuidString.prefix(6))")
        try fm.copyItem(at: backup, to: staging)
        if fm.fileExists(atPath: target.path) {
            _ = try fm.replaceItemAt(target, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: target)
        }
        // A stale WAL from the previous file would be replayed on top of the restored one.
        for suffix in ["-wal", "-shm"] { try? fm.removeItem(atPath: target.path + suffix) }
        return safety
    }

    static func sqliteHeader(_ url: URL) throws -> Bool {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        let head = try h.read(upToCount: 16) ?? Data()
        return head == Data("SQLite format 3\u{0}".utf8)
    }
}
