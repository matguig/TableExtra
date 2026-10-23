import Foundation
import MTPCore

/// Registration of `tableextra-mcp` with Claude Code (`claude mcp add/remove/get`) and the audit log reader.
public enum MCPInstaller {
    public static let serverName = "tableextra"
    public static let binaryName = "tableextra-mcp"

    /// Inside the app bundle (Contents/MacOS), else next to the running executable (swift run / tests).
    public static func binaryURL(bundle: Bundle = .main) -> URL {
        let inBundle = bundle.bundleURL.appendingPathComponent("Contents/MacOS/\(binaryName)")
        if FileManager.default.isExecutableFile(atPath: inBundle.path) { return inBundle }
        if let exe = bundle.executableURL {
            let sibling = exe.deletingLastPathComponent().appendingPathComponent(binaryName)
            if FileManager.default.isExecutableFile(atPath: sibling.path) || bundle.bundleURL.pathExtension != "app" { return sibling }
        }
        return inBundle
    }

    public static func addArguments(binaryPath: String) -> [String] {
        ["mcp", "add", "--scope", "user", serverName, "--", binaryPath]
    }

    public static func removeArguments() -> [String] { ["mcp", "remove", "--scope", "user", serverName] }

    public static func getArguments() -> [String] { ["mcp", "get", serverName] }

    /// What the user sees before confirming, e.g. `claude mcp add --scope user tableextra -- '/Applications/My App.app/…'`.
    public static func displayCommand(_ arguments: [String], claude: String = "claude") -> String {
        ([claude] + arguments).map(shellQuote).joined(separator: " ")
    }

    public static func shellQuote(_ s: String) -> String {
        if s.isEmpty { return "''" }
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./=:@%+,"))
        if s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// For Claude Desktop, Cursor and other clients that read an `mcpServers` JSON file.
    public static func jsonSnippet(binaryPath: String) -> String {
        let object: [String: Any] = ["mcpServers": [serverName: ["command": binaryPath, "args": [String]()]]]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Audit log

    /// One line of AppPaths.mcpAuditLog, as written by tableextra-mcp.
    public struct AuditEntry: Codable, Identifiable, Hashable, Sendable {
        public var ts: String
        public var tool: String
        public var connection: String?
        public var sql: String?
        public var status: String
        public var outcome: String
        public var duration_ms: Int
        public var client: String?
        public var line: Int?

        public var id: String { "\(line ?? 0)|\(ts)|\(tool)" }

        public var date: Date? {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: ts) ?? ISO8601DateFormatter().date(from: ts)
        }
    }

    /// Newest first, current file then the rotated `.1` file.
    public static func readAuditLog(url: URL = AppPaths.mcpAuditLog, limit: Int = 1_000) -> [AuditEntry] {
        var entries: [AuditEntry] = []
        let decoder = JSONDecoder()
        var counter = 0
        for file in [url.appendingPathExtension("1"), url] {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                counter += 1
                guard var e = try? decoder.decode(AuditEntry.self, from: Data(line.utf8)) else { continue }
                e.line = counter
                entries.append(e)
            }
        }
        return Array(entries.reversed().prefix(limit))
    }
}
