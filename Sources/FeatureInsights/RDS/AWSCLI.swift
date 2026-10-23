import Foundation
import MTPCore

/// Raw result of one `aws` invocation.
public struct AWSCLIOutput: Sendable, Equatable {
    public var status: Int32
    public var stdout: String
    public var stderr: String

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum AWSCLIError: Error, LocalizedError, Equatable {
    /// No `aws` executable found (or `TABLEEXTRA_AWS_CLI` points to nothing executable).
    case notInstalled
    /// Refused before launching: not one of the read-only commands TableExtra may run.
    case notAllowed(String)
    case ssoExpired(profile: String?)
    case expiredCredentials(profile: String?)
    case noCredentials(profile: String?)
    case unknownProfile(String)
    /// `permission` is the IAM action to grant (rds:DescribeDBInstances…).
    case accessDenied(permission: String, message: String)
    case notFound(String)
    case missingRegion
    case cliTooOld
    case network(String)
    case timedOut(TimeInterval)
    case cancelled
    case invalidJSON(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "The AWS CLI (v2) was not found. Install it with `brew install awscli` (or the installer from aws.amazon.com/cli), "
                + "then sign in with `aws configure sso` or `aws configure`. Set TABLEEXTRA_AWS_CLI to use a binary elsewhere."
        case .notAllowed(let command):
            return "TableExtra only runs read-only AWS commands; `aws \(command)` was refused."
        case .ssoExpired(let profile):
            return "The AWS SSO session has expired. Run `aws sso login\(Self.profileFlag(profile))` in Terminal, then refresh."
        case .expiredCredentials(let profile):
            return "The AWS credentials have expired. Renew them (for SSO: `aws sso login\(Self.profileFlag(profile))`), then refresh."
        case .noCredentials(let profile):
            return "No AWS credentials found\(profile.map { " for profile \($0)" } ?? ""). Run `aws configure sso` or `aws configure`, "
                + "or pick another profile in the connection settings."
        case .unknownProfile(let profile):
            return "The AWS profile \"\(profile)\" does not exist in ~/.aws/config. Pick one listed by `aws configure list-profiles`."
        case .accessDenied(let permission, _):
            return "Access denied: the IAM identity needs the \(permission) permission (read-only)."
        case .notFound(let message):
            return "Not found: \(message). Check the DB identifier and region in the connection settings."
        case .missingRegion:
            return "No AWS region set. Set it in the connection settings (AWS section) or in the profile."
        case .cliTooOld:
            return "This AWS CLI is version 1. TableExtra needs AWS CLI v2: `brew install awscli`."
        case .network(let message):
            return "Cannot reach AWS: \(message)"
        case .timedOut(let seconds):
            return "The AWS CLI did not answer within \(Int(seconds)) seconds."
        case .cancelled:
            return "Cancelled."
        case .invalidJSON(let text):
            return "Unexpected output from the AWS CLI: \(String(text.prefix(200)))"
        case .failed(let message):
            return message
        }
    }

    static func profileFlag(_ profile: String?) -> String {
        guard let profile, !profile.isEmpty else { return "" }
        return " --profile \(profile)"
    }
}

/// Runs the user's `aws` CLI (v2) with their profiles, read-only: only the commands in `allowedCommands` can run.
public struct AWSCLI: Sendable {
    /// `service operation` pairs TableExtra may run. Everything else is refused before launching a process.
    public static let allowedCommands: [String: String] = [
        "rds describe-db-instances": "rds:DescribeDBInstances",
        "rds describe-db-clusters": "rds:DescribeDBClusters",
        "rds describe-events": "rds:DescribeEvents",
        "rds describe-pending-maintenance-actions": "rds:DescribePendingMaintenanceActions",
        "cloudwatch get-metric-data": "cloudwatch:GetMetricData",
        "pi describe-dimension-keys": "pi:DescribeDimensionKeys",
        "pi get-resource-metrics": "pi:GetResourceMetrics",
        "configure list-profiles": "(none: reads ~/.aws/config)",
        "sts get-caller-identity": "(none: always allowed)",
    ]
    /// Options a caller may not pass: they would change where or how the command runs.
    static let reservedOptions: Set<String> = ["--profile", "--region", "--output", "--endpoint-url", "--cli-input-json",
                                               "--cli-input-yaml", "--generate-cli-skeleton", "--debug", "--query", "--no-cli-pager"]

    public static let standardLocations = ["/opt/homebrew/bin/aws", "/usr/local/bin/aws"]
    public static let defaultTimeout: TimeInterval = 45

    public let executableURL: URL?
    public var timeout: TimeInterval

    public init(executableURL: URL?, timeout: TimeInterval = AWSCLI.defaultTimeout) {
        self.executableURL = executableURL
        self.timeout = timeout
    }

    /// The binary found by `locate()`.
    public static func resolved() -> AWSCLI { AWSCLI(executableURL: locate()) }

    /// `TABLEEXTRA_AWS_CLI`, then the Homebrew / installer locations, then the login shell's `command -v aws`.
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment,
                              candidates: [String] = standardLocations, useLoginShell: Bool = true) -> URL? {
        let fm = FileManager.default
        if let override = environment["TABLEEXTRA_AWS_CLI"], !override.trimmingCharacters(in: .whitespaces).isEmpty {
            let path = (override as NSString).expandingTildeInPath
            return fm.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        for c in candidates where fm.isExecutableFile(atPath: c) { return URL(fileURLWithPath: c) }
        guard useLoginShell,
              let out = try? AWSProcessRunner.run(URL(fileURLWithPath: "/bin/zsh"), arguments: ["-lc", "command -v aws"], timeout: 10),
              out.status == 0 else { return nil }
        let path = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").last ?? ""
        return path.hasPrefix("/") && fm.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    // MARK: Arguments

    /// Full argument list, or `notAllowed` when the command is not a read-only one TableExtra knows.
    public static func arguments(service: String, operation: String, arguments extra: [String] = [],
                                 settings: AWSSettings?) throws -> [String] {
        let command = "\(service) \(operation)"
        guard allowedCommands[command] != nil else { throw AWSCLIError.notAllowed(command) }
        for a in extra {
            let name = a.split(separator: "=", maxSplits: 1).first.map(String.init) ?? a
            if reservedOptions.contains(name) { throw AWSCLIError.notAllowed("\(command) \(name)") }
        }
        var args = [service, operation] + extra
        if let profile = settings?.profile?.trimmingCharacters(in: .whitespaces), !profile.isEmpty {
            args += ["--profile", profile]
        }
        if let region = settings?.region?.trimmingCharacters(in: .whitespaces), !region.isEmpty {
            args += ["--region", region]
        }
        args += ["--output", "json", "--no-cli-pager"]
        return args
    }

    /// Process environment: login-shell PATH (GUI apps get a minimal one), no pager, no auto-prompt.
    public static func environment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        env["PATH"] = loginShellPATH()
        env["AWS_PAGER"] = ""
        env["AWS_CLI_AUTO_PROMPT"] = "off"
        env.removeValue(forKey: "AWS_DEFAULT_OUTPUT")
        return env
    }

    // MARK: Running

    /// Runs an allowed command and returns its raw output (any exit status).
    public func run(_ service: String, _ operation: String, _ arguments: [String] = [], settings: AWSSettings?) async throws -> AWSCLIOutput {
        let args = try Self.arguments(service: service, operation: operation, arguments: arguments, settings: settings)
        guard let url = executableURL else { throw AWSCLIError.notInstalled }
        let env = Self.environment()
        let limit = timeout
        let box = AWSProcessBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<AWSCLIOutput, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        cont.resume(returning: try AWSProcessRunner.run(url, arguments: args, environment: env, timeout: limit, box: box))
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            box.cancel()
        }
    }

    /// Runs an allowed command and returns its JSON stdout; a failure becomes a friendly `AWSCLIError`.
    public func json(_ service: String, _ operation: String, _ arguments: [String] = [], settings: AWSSettings?) async throws -> Data {
        let out = try await run(service, operation, arguments, settings: settings)
        try Self.check(out, command: "\(service) \(operation)", profile: settings?.profile)
        let text = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = Data(text.isEmpty ? "{}".utf8 : text.utf8)
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else { throw AWSCLIError.invalidJSON(text) }
        return data
    }

    /// Throws the mapped error for a non-zero exit.
    static func check(_ out: AWSCLIOutput, command: String, profile: String?) throws {
        guard out.status != 0 else { return }
        throw mapError(out.stderr.isEmpty ? out.stdout : out.stderr, command: command, profile: profile)
    }

    /// Turns the CLI's stderr into an actionable error.
    public static func mapError(_ stderr: String, command: String, profile: String?) -> AWSCLIError {
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        let profile = profile?.isEmpty == false ? profile : nil
        if lower.contains("the config profile (") && lower.contains("could not be found") {
            let name = text.range(of: #"profile \(([^)]*)\)"#, options: .regularExpression)
                .map { String(text[$0]).replacingOccurrences(of: "profile (", with: "").replacingOccurrences(of: ")", with: "") }
            return .unknownProfile(name ?? profile ?? "?")
        }
        if lower.contains("the sso session") || lower.contains("token has expired") || lower.contains("error when retrieving token from sso")
            || lower.contains("sso token") && lower.contains("expired") || lower.contains("unauthorizedexception") && lower.contains("sso") {
            return .ssoExpired(profile: profile)
        }
        if lower.contains("expiredtoken") || lower.contains("security token included in the request is expired")
            || lower.contains("requestexpired") {
            return .expiredCredentials(profile: profile)
        }
        if lower.contains("unable to locate credentials") || lower.contains("no credentials") {
            return .noCredentials(profile: profile)
        }
        if lower.contains("you must specify a region") || lower.contains("noregionerror") {
            return .missingRegion
        }
        if lower.contains("unknown options: --no-cli-pager") || lower.contains("unknown options") && lower.contains("no-cli-pager") {
            return .cliTooOld
        }
        if lower.contains("accessdenied") || lower.contains("notauthorized") || lower.contains("is not authorized to perform")
            || lower.contains("unauthorizedoperation") {
            let action = text.range(of: #"not authorized to perform: [A-Za-z0-9-]+:[A-Za-z0-9]+"#, options: .regularExpression)
                .map { String(text[$0].dropFirst("not authorized to perform: ".count)) }
            return .accessDenied(permission: action ?? allowedCommands[command] ?? command, message: firstLine(text))
        }
        if lower.contains("notfound") || lower.contains("not found") {
            return .notFound(errorMessage(text))
        }
        if lower.contains("could not connect to the endpoint url") || lower.contains("connect timeout") || lower.contains("name or service not known") {
            return .network(firstLine(text))
        }
        return .failed(text.isEmpty ? "aws \(command) failed" : errorMessage(text))
    }

    /// "An error occurred (X) when calling the Y operation: message" → "message".
    static func errorMessage(_ text: String) -> String {
        let line = firstLine(text)
        if let r = line.range(of: " operation: ") { return String(line[r.upperBound...]) }
        return line
    }

    static func firstLine(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").first { !$0.isEmpty } ?? s
    }

    // MARK: Helpers for settings screens

    /// Profiles from `aws configure list-profiles` (empty when the CLI is missing or fails).
    public func listProfiles() async -> [String] {
        guard let out = try? await run("configure", "list-profiles", settings: nil), out.status == 0 else { return [] }
        return out.stdout.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// "arn:aws:sts::123456789012:assumed-role/ReadOnly/jane (account 123456789012)" — proves the profile works.
    public func callerIdentity(_ settings: AWSSettings) async throws -> String {
        let data = try await json("sts", "get-caller-identity", settings: settings)
        let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let arn = o["Arn"] as? String ?? "?"
        if let account = o["Account"] as? String { return "\(arn) (account \(account))" }
        return arn
    }

    public static func listProfiles() async -> [String] { await resolved().listProfiles() }
    public static func callerIdentity(_ settings: AWSSettings) async throws -> String { try await resolved().callerIdentity(settings) }

    // MARK: PATH

    nonisolated(unsafe) private static var cachedPath: String?
    private static let pathLock = NSLock()

    static func loginShellPATH() -> String {
        pathLock.lock()
        defer { pathLock.unlock() }
        if let cachedPath { return cachedPath }
        let current = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        var path = current
        if let out = try? AWSProcessRunner.run(URL(fileURLWithPath: "/bin/zsh"), arguments: ["-lc", "printf '%s' \"$PATH\""], timeout: 10),
           out.status == 0, !out.stdout.isEmpty {
            path = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").last ?? current
        }
        var parts = path.split(separator: ":").map(String.init)
        for e in ["/opt/homebrew/bin", "/usr/local/bin"] where !parts.contains(e) { parts.append(e) }
        path = parts.joined(separator: ":")
        cachedPath = path
        return path
    }
}

/// Lets a running process be terminated from another thread (cancellation, timeout).
final class AWSProcessBox: @unchecked Sendable {
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

enum AWSProcessRunner {
    /// Blocking: launches, collects both pipes, honours timeout and cancellation. stdin is closed (no prompts).
    static func run(_ url: URL, arguments: [String], environment: [String: String]? = nil, timeout: TimeInterval,
                    box: AWSProcessBox = AWSProcessBox()) throws -> AWSCLIOutput {
        guard FileManager.default.isExecutableFile(atPath: url.path) else { throw AWSCLIError.notInstalled }
        let p = Process()
        p.executableURL = url
        p.arguments = arguments
        if let environment { p.environment = environment }
        p.currentDirectoryURL = FileManager.default.temporaryDirectory
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.standardInput = FileHandle.nullDevice

        guard box.attach(p) else { throw AWSCLIError.cancelled }
        do { try p.run() } catch { throw AWSCLIError.failed("Cannot launch \(url.path): \(error.localizedDescription)") }
        if box.isCancelled { box.cancel() }

        let timer = DispatchWorkItem { box.timeOut() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        defer { timer.cancel() }

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
        let stopped = box.isCancelled || box.didTimeOut
        _ = group.wait(timeout: .now() + (stopped ? 1 : 30))

        if box.isCancelled { throw AWSCLIError.cancelled }
        if box.didTimeOut { throw AWSCLIError.timedOut(timeout) }
        let (out, err) = collected.get()
        return AWSCLIOutput(status: p.terminationStatus, stdout: String(decoding: out, as: UTF8.self), stderr: String(decoding: err, as: UTF8.self))
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
