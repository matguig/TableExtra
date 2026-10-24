import Foundation
import MTPAgentTools

/// Read-only access to the connection's code repository for the API backend (the CLI backend uses Claude Code's
/// Read/Grep/Glob instead). Every path is resolved inside `root`; symlinks leaving it are refused.
public struct RepoTools: Sendable {
    public static let names = ["read_file", "grep", "list_files"]
    static let skippedDirectories: Set<String> = [".git", ".hg", ".svn", "node_modules", ".build", "build", "dist", "DerivedData",
                                                  "Pods", ".venv", "venv", "__pycache__", ".next", ".nuxt", "target", "coverage", ".turbo"]
    static let maxFileBytes = 1_000_000
    static let maxFilesScanned = 20_000

    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Claude API tool definitions.
    public static var definitions: [JSONValue] {
        [
            [
                "name": "read_file",
                "description": "Reads a text file of the application's code repository, with line numbers. Paths are relative to the repository root.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "File path relative to the repository root."],
                        "offset": ["type": "integer", "description": "First line to return (1-based, default 1).", "minimum": 1],
                        "limit": ["type": "integer", "description": "Number of lines (default 400, at most 2000).", "minimum": 1, "maximum": 2000],
                    ],
                    "required": ["path"],
                    "additionalProperties": false,
                ],
            ],
            [
                "name": "grep",
                "description": "Searches the repository's text files with a regular expression (case-insensitive by default) and returns path:line: text matches.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "pattern": ["type": "string", "description": "Regular expression (ICU syntax)."],
                        "path": ["type": "string", "description": "Folder or file to search, relative to the root (default: everything)."],
                        "glob": ["type": "string", "description": "Only files matching this glob, e.g. \"**/*.ts\" or \"*.sql\"."],
                        "case_sensitive": ["type": "boolean", "default": false],
                        "max_results": ["type": "integer", "description": "Default 100, at most 500.", "minimum": 1, "maximum": 500],
                    ],
                    "required": ["pattern"],
                    "additionalProperties": false,
                ],
            ],
            [
                "name": "list_files",
                "description": "Lists repository files matching a glob (\"**\" crosses folders), e.g. \"**/migrations/*.sql\" or \"src/**/*.ts\". Dependency and build folders are skipped.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "pattern": ["type": "string", "description": "Glob relative to the root (default \"**/*\")."],
                        "max_results": ["type": "integer", "description": "Default 300, at most 2000.", "minimum": 1, "maximum": 2000],
                    ],
                    "additionalProperties": false,
                ],
            ],
        ]
    }

    public struct Failure: LocalizedError {
        public var errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    public func call(_ name: String, arguments: [String: JSONValue]) -> ToolResult {
        do {
            let text: String
            switch name {
            case "read_file": text = try readFile(arguments)
            case "grep": text = try grep(arguments)
            case "list_files": text = try listFiles(arguments)
            default: throw Failure("Unknown tool \(name)")
            }
            return ToolResult(text: text, isError: false)
        } catch {
            return ToolResult(text: error.localizedDescription, isError: true)
        }
    }

    // MARK: Paths

    /// `relative` inside the root, or a Failure.
    func resolve(_ relative: String) throws -> URL {
        let trimmed = relative.trimmingCharacters(in: .whitespaces)
        let candidate = trimmed.hasPrefix("/") ? URL(fileURLWithPath: trimmed) : root.appendingPathComponent(trimmed)
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path == root.path || resolved.path.hasPrefix(root.path + "/") else {
            throw Failure("\(relative) is outside the repository.")
        }
        return resolved
    }

    func relativePath(_ url: URL) -> String {
        let p = url.standardizedFileURL.path
        return p.hasPrefix(root.path + "/") ? String(p.dropFirst(root.path.count + 1)) : p
    }

    /// Text content, or nil for binary or oversized files.
    static func text(of url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attrs[.size] as? NSNumber)?.intValue ?? 0 <= maxFileBytes,
              let data = try? Data(contentsOf: url), !data.prefix(8_192).contains(0) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Regular files under `start`, skipping dependency and build folders, in path order.
    func files(under start: URL) -> [URL] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: start.path, isDirectory: &isDir) else { return [] }
        guard isDir.boolValue else { return [start] }
        guard let e = FileManager.default.enumerator(at: start, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                                                     options: [.skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        for case let url as URL in e {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values?.isDirectory == true {
                if Self.skippedDirectories.contains(url.lastPathComponent) { e.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            out.append(url)
            if out.count >= Self.maxFilesScanned { break }
        }
        return out.sorted { $0.path < $1.path }
    }

    // MARK: Tools

    func readFile(_ args: [String: JSONValue]) throws -> String {
        guard let path = args["path"]?.stringValue, !path.isEmpty else { throw Failure("Missing `path`.") }
        let url = try resolve(path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { throw Failure("\(path) does not exist.") }
        guard !isDir.boolValue else { throw Failure("\(path) is a folder: use list_files.") }
        guard let text = Self.text(of: url) else { throw Failure("\(path) is binary or larger than 1 MB.") }
        let lines = text.components(separatedBy: "\n")
        let offset = max(1, args["offset"]?.intValue ?? 1)
        let limit = min(2_000, max(1, args["limit"]?.intValue ?? 400))
        guard offset <= lines.count else { return "(\(path) has \(lines.count) lines)" }
        let end = min(lines.count, offset - 1 + limit)
        var out = lines[(offset - 1)..<end].enumerated().map { i, line in
            let l = line.count > 2_000 ? String(line.prefix(2_000)) + "…" : line
            return String(format: "%6d\t", offset + i) + l
        }.joined(separator: "\n")
        if end < lines.count { out += "\n… \(lines.count - end) more lines (use offset \(end + 1))" }
        return out
    }

    func grep(_ args: [String: JSONValue]) throws -> String {
        guard let pattern = args["pattern"]?.stringValue, !pattern.isEmpty else { throw Failure("Missing `pattern`.") }
        let options: NSRegularExpression.Options = args["case_sensitive"]?.boolValue == true ? [] : [.caseInsensitive]
        let regex: NSRegularExpression
        do { regex = try NSRegularExpression(pattern: pattern, options: options) } catch { throw Failure("Invalid regular expression: \(pattern)") }
        let start = try resolve(args["path"]?.stringValue ?? "")
        let glob = args["glob"]?.stringValue.flatMap { Self.globRegex($0) }
        let limit = min(500, max(1, args["max_results"]?.intValue ?? 100))
        var matches: [String] = []
        var truncated = false
        scan: for file in files(under: start) {
            let rel = relativePath(file)
            if let glob, !Self.matches(glob, rel) && !Self.matches(glob, file.lastPathComponent) { continue }
            guard let text = Self.text(of: file) else { continue }
            for (i, line) in text.components(separatedBy: "\n").enumerated()
            where regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                if matches.count >= limit { truncated = true; break scan }
                let shown = line.trimmingCharacters(in: .whitespaces)
                matches.append("\(rel):\(i + 1): \(shown.count > 300 ? String(shown.prefix(300)) + "…" : shown)")
            }
        }
        if matches.isEmpty { return "No matches." }
        return matches.joined(separator: "\n") + (truncated ? "\n… more matches not shown (narrow the pattern or path)" : "")
    }

    func listFiles(_ args: [String: JSONValue]) throws -> String {
        let pattern = args["pattern"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "**/*"
        guard let regex = Self.globRegex(pattern) else { throw Failure("Invalid glob: \(pattern)") }
        let limit = min(2_000, max(1, args["max_results"]?.intValue ?? 300))
        let found = files(under: root).map(relativePath).filter { Self.matches(regex, $0) }
        if found.isEmpty { return "No files match \(pattern)." }
        return found.prefix(limit).joined(separator: "\n") + (found.count > limit ? "\n… \(found.count - limit) more files" : "")
    }

    // MARK: Globs

    /// `**/` any folders (or none), `**` anything, `*` and `?` within one path component, `{a,b}` alternatives.
    static func globRegex(_ glob: String) -> NSRegularExpression? {
        var g = glob.trimmingCharacters(in: .whitespaces)
        if g.hasPrefix("./") { g.removeFirst(2) }
        var p = "^"
        var i = g.startIndex
        var inBraces = false
        while i < g.endIndex {
            let c = g[i]
            let next = g.index(after: i)
            switch c {
            case "*":
                if next < g.endIndex, g[next] == "*" {
                    let after = g.index(after: next)
                    if after < g.endIndex, g[after] == "/" {
                        p += "(?:.*/)?"
                        i = g.index(after: after)
                    } else {
                        p += ".*"
                        i = after
                    }
                    continue
                }
                p += "[^/]*"
            case "?": p += "[^/]"
            case "{": p += "(?:"; inBraces = true
            case "}" where inBraces: p += ")"; inBraces = false
            case "," where inBraces: p += "|"
            default: p += NSRegularExpression.escapedPattern(for: String(c))
            }
            i = next
        }
        return try? NSRegularExpression(pattern: p + "$")
    }

    static func matches(_ regex: NSRegularExpression, _ s: String) -> Bool {
        regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
}
