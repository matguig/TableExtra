import Foundation

public enum ClaudeCLIError: LocalizedError, Equatable {
    case notFound
    case notLoggedIn(String)
    case timedOut(TimeInterval)
    case cancelled
    case failed(String)
    case invalidOutput(String)

    public var errorDescription: String? {
        switch self {
        case .notFound:
            return "The claude CLI was not found. Install Claude Code (https://claude.com/claude-code) or set its path in Settings → AI."
        case .notLoggedIn(let message):
            return "Claude Code is not logged in (\(message)). Run `claude` in a terminal and use /login."
        case .timedOut(let seconds):
            return "Claude did not answer within \(Int(seconds)) s."
        case .cancelled:
            return "Cancelled."
        case .failed(let message):
            return "Claude failed: \(message)"
        case .invalidOutput(let output):
            return "Unexpected output from claude: \(output.prefix(300))"
        }
    }
}

public struct ClaudeResponse: Sendable, Equatable {
    public var text: String
    public var model: String?
    public var durationMS: Int?
    public var costUSD: Double?
}

public struct ProcessOutput: Sendable, Equatable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
}

/// Runs the local `claude` CLI non-interactively (`-p`, JSON output, no tools, no saved session).
/// Uses the user's Claude Code login: no API key involved.
public struct ClaudeCLI: Sendable {
    public static let modelAliases = AIModels.aliases
    public static let defaultTimeout: TimeInterval = 180

    public let executableURL: URL

    public init(executableURL: URL) {
        self.executableURL = executableURL
    }

    /// The configured or auto-detected binary.
    public static func resolved() throws -> ClaudeCLI {
        guard let url = locate() else { throw ClaudeCLIError.notFound }
        return ClaudeCLI(executableURL: url)
    }

    // MARK: Locating

    public static let standardLocations = ["~/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]

    /// UserDefaults override, then the usual install locations, then the login shell's `command -v claude`.
    public static func locate(override: String? = AISettings.claudePath, candidates: [String] = standardLocations,
                              useLoginShell: Bool = true) -> URL? {
        let fm = FileManager.default
        if let override, !override.trimmingCharacters(in: .whitespaces).isEmpty {
            let path = (override as NSString).expandingTildeInPath
            return fm.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        for c in candidates {
            let path = (c as NSString).expandingTildeInPath
            if fm.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        guard useLoginShell,
              let out = try? ProcessRunner.run(URL(fileURLWithPath: "/bin/zsh"), arguments: ["-lc", "command -v claude"], timeout: 10),
              out.status == 0 else { return nil }
        let path = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").last ?? ""
        return path.hasPrefix("/") && fm.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    // MARK: Prompting

    /// Read-only capabilities granted to one request. Nothing by default: Claude then only sees the prompt.
    public struct Access: Sendable, Equatable {
        /// Application code Claude may browse with Read/Grep/Glob (never Edit/Write/Bash).
        public var codeRepository: URL?
        /// `tableextra-mcp` launched for this connection only, read-only (list/describe/search/run_query/explain).
        public var databaseTools: DatabaseTools?

        public struct DatabaseTools: Sendable, Equatable {
            public var serverBinary: URL
            public var connectionID: UUID
            public var environment: [String: String]

            public init(serverBinary: URL, connectionID: UUID, environment: [String: String] = [:]) {
                self.serverBinary = serverBinary
                self.connectionID = connectionID
                self.environment = environment
            }
        }

        public init(codeRepository: URL? = nil, databaseTools: DatabaseTools? = nil) {
            self.codeRepository = codeRepository
            self.databaseTools = databaseTools
        }

        public static let none = Access()
        public var usesTools: Bool { codeRepository != nil || databaseTools != nil }
    }

    /// Read-only database tools of `tableextra-mcp` the assistant may call (never execute_statement).
    public static let databaseToolNames = ["list_schemas", "list_tables", "describe_table", "search_schema", "run_query", "explain_query"]

    public static func promptArguments(model: String?, systemPrompt: String?, access: Access = .none) -> [String] {
        // Only the user's own settings: a repository's .claude/settings.json (hooks, permissions) is never loaded.
        var args = ["-p", "--output-format", "json", "--no-session-persistence", "--strict-mcp-config",
                    "--setting-sources", "user", "--disable-slash-commands"]
        var allowed: [String] = []
        if let repo = access.codeRepository {
            args += ["--tools", "Read,Grep,Glob", "--add-dir", repo.path]
            allowed += ["Read", "Grep", "Glob"]
        } else {
            args += ["--tools", ""]
        }
        if let db = access.databaseTools {
            var env = db.environment
            env["TABLEEXTRA_MCP_ONLY"] = db.connectionID.uuidString
            let config: [String: Any] = ["mcpServers": ["tableextra": ["command": db.serverBinary.path, "args": [String](), "env": env]]]
            if let data = try? JSONSerialization.data(withJSONObject: config), let json = String(data: data, encoding: .utf8) {
                args += ["--mcp-config", json]
                allowed += databaseToolNames.map { "mcp__tableextra__\($0)" }
            }
        }
        if !allowed.isEmpty { args += ["--allowedTools", allowed.joined(separator: ",")] }
        if let model, !model.isEmpty { args += ["--model", model] }
        if let systemPrompt, !systemPrompt.isEmpty { args += ["--system-prompt", systemPrompt] }
        return args
    }

    /// Sends `prompt` on stdin and returns the `result` text. Task cancellation terminates the process.
    public func ask(_ prompt: String, model: String? = nil, systemPrompt: String? = nil, access: Access = .none,
                    timeout: TimeInterval = ClaudeCLI.defaultTimeout) async throws -> ClaudeResponse {
        // Tool use (reading code, querying) takes several round trips: allow more time.
        let limit = access.usesTools ? max(timeout, 420) : timeout
        let out = try await run(Self.promptArguments(model: model, systemPrompt: systemPrompt, access: access), stdin: prompt,
                                timeout: limit, workingDirectory: access.codeRepository)
        return try Self.parse(out)
    }

    /// Any other subcommand (`mcp get …`), returning raw output.
    public func run(_ arguments: [String], stdin: String? = nil, timeout: TimeInterval = 60,
                    workingDirectory: URL? = nil) async throws -> ProcessOutput {
        let url = executableURL
        let env = Self.environment()
        let box = ProcessBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ProcessOutput, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let cwd = workingDirectory ?? FileManager.default.temporaryDirectory
                        cont.resume(returning: try ProcessRunner.run(url, arguments: arguments, environment: env, stdin: stdin,
                                                                     currentDirectory: cwd, timeout: timeout, box: box))
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            box.cancel()
        }
    }

    /// Decodes `--output-format json` output (one result object, or an array of messages ending with one).
    public static func parse(_ out: ProcessOutput) throws -> ClaudeResponse {
        let object = resultObject(in: out.stdout)
        guard let object else {
            let message = [out.stderr, out.stdout].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
            if let message, isLoginMessage(message) { throw ClaudeCLIError.notLoggedIn(firstLine(message)) }
            if out.status != 0 { throw ClaudeCLIError.failed(message.map(firstLine) ?? "exit status \(out.status)") }
            throw ClaudeCLIError.invalidOutput(out.stdout)
        }
        let text = object["result"] as? String ?? ""
        let isError = object["is_error"] as? Bool ?? false
        if isError || (out.status != 0 && text.isEmpty) {
            let message = text.isEmpty ? (out.stderr.isEmpty ? "exit status \(out.status)" : firstLine(out.stderr)) : text
            if isLoginMessage(message) { throw ClaudeCLIError.notLoggedIn(firstLine(message)) }
            throw ClaudeCLIError.failed(message)
        }
        let model = (object["modelUsage"] as? [String: Any])?.keys.sorted().first
        return ClaudeResponse(text: text, model: model, durationMS: object["duration_ms"] as? Int,
                              costUSD: object["total_cost_usd"] as? Double)
    }

    static func resultObject(in stdout: String) -> [String: Any]? {
        func decode(_ s: Substring) -> Any? { try? JSONSerialization.jsonObject(with: Data(s.utf8)) }
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates: [Any] = []
        if let whole = decode(Substring(trimmed)) {
            candidates.append(whole)
        } else {
            candidates = trimmed.split(separator: "\n").compactMap { decode($0) }
        }
        var objects: [[String: Any]] = []
        for c in candidates {
            if let array = c as? [[String: Any]] { objects += array } else if let o = c as? [String: Any] { objects.append(o) }
        }
        return objects.last { $0["type"] as? String == "result" } ?? objects.last { $0["result"] != nil }
    }

    static func isLoginMessage(_ s: String) -> Bool {
        let l = s.lowercased()
        return l.contains("not logged in") || l.contains("/login") || l.contains("invalid api key") || l.contains("please log in")
    }

    private static func firstLine(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").first ?? s
    }

    // MARK: Environment

    nonisolated(unsafe) private static var cachedPath: String?
    private static let pathLock = NSLock()

    /// Process environment with the login shell's PATH (GUI apps get a minimal one) and without
    /// the variables that would make claude think it runs nested inside another Claude Code session.
    public static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        env.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
        env["PATH"] = loginShellPATH()
        return env
    }

    static func loginShellPATH() -> String {
        pathLock.lock()
        defer { pathLock.unlock() }
        if let cachedPath { return cachedPath }
        let current = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        var path = current
        if let out = try? ProcessRunner.run(URL(fileURLWithPath: "/bin/zsh"), arguments: ["-lc", "printf '%s' \"$PATH\""], timeout: 10),
           out.status == 0, !out.stdout.isEmpty {
            path = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").last ?? current
        }
        let extras = ["~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"].map { ($0 as NSString).expandingTildeInPath }
        var parts = path.split(separator: ":").map(String.init)
        for e in extras where !parts.contains(e) { parts.append(e) }
        path = parts.joined(separator: ":")
        cachedPath = path
        return path
    }
}

/// Lets a running process be terminated from another thread (cancellation, timeout).
final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private(set) var isCancelled = false
    private(set) var didTimeOut = false

    func attach(_ p: Process) -> Bool {
        lock.lock(); defer { lock.unlock() }
        process = p
        return !isCancelled
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let p = process
        lock.unlock()
        Self.stop(p)
    }

    func timeOut() {
        lock.lock()
        didTimeOut = true
        let p = process
        lock.unlock()
        Self.stop(p)
    }

    private static func stop(_ p: Process?) {
        guard let p, p.isRunning else { return }
        p.terminate()
        let pid = p.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if p.isRunning { kill(pid, SIGKILL) }
        }
    }
}

enum ProcessRunner {
    private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()

    /// Blocking: launches, feeds stdin, collects both pipes, honours timeout and cancellation.
    static func run(_ url: URL, arguments: [String], environment: [String: String]? = nil, stdin: String? = nil,
                    currentDirectory: URL? = nil, timeout: TimeInterval, box: ProcessBox = ProcessBox()) throws -> ProcessOutput {
        _ = ignoreSIGPIPE
        guard FileManager.default.isExecutableFile(atPath: url.path) else { throw ClaudeCLIError.notFound }
        let p = Process()
        p.executableURL = url
        p.arguments = arguments
        if let environment { p.environment = environment }
        if let currentDirectory { p.currentDirectoryURL = currentDirectory }
        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.standardInput = inPipe

        guard box.attach(p) else { throw ClaudeCLIError.cancelled }
        do { try p.run() } catch { throw ClaudeCLIError.failed("cannot launch \(url.path): \(error.localizedDescription)") }
        if box.isCancelled { box.cancel() }

        let timer = DispatchWorkItem { box.timeOut() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        defer { timer.cancel() }

        let writer = inPipe.fileHandleForWriting
        DispatchQueue.global().async {
            if let stdin { try? writer.write(contentsOf: Data(stdin.utf8)) }
            try? writer.close()
        }
        let collected = Collected()
        let group = DispatchGroup()
        for (pipe, isOut) in [(outPipe, true), (errPipe, false)] {
            group.enter()
            DispatchQueue.global().async {
                collected.set(pipe.fileHandleForReading.readDataToEndOfFile(), stdout: isOut)
                group.leave()
            }
        }
        p.waitUntilExit()
        // A killed process may leave children holding the pipes open: do not wait for them forever.
        let stopped = box.isCancelled || box.didTimeOut
        _ = group.wait(timeout: .now() + (stopped ? 1 : 30))

        if box.isCancelled { throw ClaudeCLIError.cancelled }
        if box.didTimeOut { throw ClaudeCLIError.timedOut(timeout) }
        let (out, err) = collected.get()
        return ProcessOutput(status: p.terminationStatus,
                             stdout: String(decoding: out, as: UTF8.self),
                             stderr: String(decoding: err, as: UTF8.self))
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data(), err = Data()

        func set(_ data: Data, stdout: Bool) {
            lock.lock(); defer { lock.unlock() }
            if stdout { out = data } else { err = data }
        }

        func get() -> (Data, Data) {
            lock.lock(); defer { lock.unlock() }
            return (out, err)
        }
    }
}
