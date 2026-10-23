import Foundation

/// One JSON object per line in AppPaths.mcpAuditLog:
/// {"ts":"2026-10-23T09:12:03.120Z","tool":"run_query","connection":"shop","sql":"SELECT …","status":"ok","outcome":"12 rows","duration_ms":8,"client":"claude-code"}
/// MCPSettingsView (FeatureAI) reads the same keys.
struct AuditEntry: Codable, Equatable, Sendable {
    var ts: String
    var tool: String
    var connection: String?
    var sql: String?
    /// "ok", "refused" or "error".
    var status: String
    var outcome: String
    var duration_ms: Int
    var client: String?
}

final class AuditLog: @unchecked Sendable {
    static let maxSQLLength = 2000
    static let rotateBytes: UInt64 = 5 * 1024 * 1024

    let url: URL
    private let lock = NSLock()

    init(url: URL) { self.url = url }

    static func timestamp(_ date: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    static func truncate(_ sql: String?) -> String? {
        guard let sql else { return nil }
        let s = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        return s.count > maxSQLLength ? String(s.prefix(maxSQLLength)) + "… [\(s.count) chars]" : s
    }

    func append(_ entry: AuditEntry) {
        var e = entry
        e.sql = Self.truncate(e.sql)
        e.outcome = e.outcome.count > 500 ? String(e.outcome.prefix(500)) + "…" : e.outcome
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var data = try? encoder.encode(e) else { return }
        data.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? UInt64, size > Self.rotateBytes {
            let old = url.appendingPathExtension("1")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        // O_APPEND keeps lines whole when several server processes (one per Claude session) write at once.
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else {
            stderrLog("cannot open audit log at \(url.path)")
            return
        }
        defer { close(fd) }
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }
}

/// Diagnostics go to stderr: stdout carries JSON-RPC only.
func stderrLog(_ message: String) {
    FileHandle.standardError.write(Data("[tableextra-mcp] \(message)\n".utf8))
}
