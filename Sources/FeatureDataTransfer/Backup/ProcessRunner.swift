import Foundation
import MTPCore

/// Runs a command-line tool and streams its stdout/stderr line by line. `terminate()` may be called from anywhere.
public final class ProcessRunner: @unchecked Sendable {
    public enum Stream: Sendable { case stdout, stderr }

    public struct Outcome: Sendable {
        public var status: Int32
        public var wasTerminated: Bool
        public var succeeded: Bool { status == 0 && !wasTerminated }
    }

    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]
    /// Optional in-process source written to stdin (e.g. a decompressed .sql.gz).
    public let stdinFeeder: StdinFeeder?

    /// Writes the tool's input to a file descriptor, on its own thread, then returns; `label` stands for it in `commandLine`.
    public struct StdinFeeder: Sendable {
        public var label: String
        public var write: @Sendable (_ fd: Int32) throws -> Void

        public init(label: String, write: @escaping @Sendable (_ fd: Int32) throws -> Void) {
            self.label = label
            self.write = write
        }
    }

    private let lock = NSLock()
    private var process: Process?
    private var terminated = false
    private var feederFailed = false

    public init(executable: URL, arguments: [String], environment: [String: String], stdinFeeder: StdinFeeder? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.stdinFeeder = stdinFeeder
    }

    /// Shell-like rendering for the log; values of `--password`-like flags never appear since secrets go through the environment.
    public var commandLine: String {
        var parts = [executable.path] + arguments
        parts = parts.map { $0.contains(where: { " \"'$`\\".contains($0) }) ? "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" : $0 }
        let cmd = parts.joined(separator: " ")
        guard let feeder = stdinFeeder else { return cmd }
        return feeder.label + " | " + cmd
    }

    public func run(onLine: @escaping @Sendable (Stream, String) -> Void) async throws -> Outcome {
        let p = Process()
        p.executableURL = executable
        p.arguments = arguments
        p.environment = environment
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err

        let link: Pipe? = stdinFeeder.map { _ in
            let link = Pipe()
            // A write after the tool exits must fail with EPIPE, not kill the app with SIGPIPE.
            _ = fcntl(link.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            p.standardInput = link
            return link
        }
        if link == nil { p.standardInput = FileHandle.nullDevice }

        let outLines = LineSplitter { onLine(.stdout, $0) }
        let errLines = LineSplitter { onLine(.stderr, $0) }
        out.fileHandleForReading.readabilityHandler = { h in outLines.append(h.availableData) }
        err.fileHandleForReading.readabilityHandler = { h in errLines.append(h.availableData) }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Outcome, Error>) in
            p.terminationHandler = { [weak self] proc in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                outLines.append(out.fileHandleForReading.readDataToEndOfFile())
                errLines.append(err.fileHandleForReading.readDataToEndOfFile())
                outLines.flush()
                errLines.flush()
                let killed = self?.wasTerminated ?? false
                // The feeder closes stdin only after recording its failure, so the flag is set by the time the tool exits.
                var status = proc.terminationStatus
                if self?.didFeederFail == true, status == 0 { status = 1 }
                cont.resume(returning: Outcome(status: status, wasTerminated: killed || proc.terminationReason == .uncaughtSignal))
            }
            do {
                lock.lock()
                process = p
                let alreadyCancelled = terminated
                lock.unlock()
                if alreadyCancelled {
                    p.terminationHandler = nil
                    cont.resume(returning: Outcome(status: -1, wasTerminated: true))
                    return
                }
                try p.run()
                if let link, let feeder = stdinFeeder {
                    Thread.detachNewThread { [weak self] in
                        let fd = link.fileHandleForWriting.fileDescriptor
                        do {
                            try feeder.write(fd)
                        } catch {
                            errLines.append(Data((error.localizedDescription + "\n").utf8))
                            self?.markFeederFailed()
                        }
                        try? link.fileHandleForWriting.close()
                    }
                }
            } catch {
                p.terminationHandler = nil
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                cont.resume(throwing: error)
            }
        }
    }

    private var wasTerminated: Bool {
        lock.lock(); defer { lock.unlock() }
        return terminated
    }

    private var didFeederFail: Bool {
        lock.lock(); defer { lock.unlock() }
        return feederFailed
    }

    private func markFeederFailed() {
        lock.lock()
        feederFailed = true
        lock.unlock()
    }

    /// Stops the tool; a running feeder then gets EPIPE and returns.
    public func terminate() {
        lock.lock()
        terminated = true
        let p = process
        lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }
}

/// Accumulates bytes and emits complete UTF-8 lines.
final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let emit: (String) -> Void

    init(_ emit: @escaping (String) -> Void) { self.emit = emit }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        buffer.append(data)
        var lines: [String] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            lines.append(String(decoding: line, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        lock.unlock()
        lines.forEach(emit)
    }

    func flush() {
        lock.lock()
        let rest = buffer
        buffer = Data()
        lock.unlock()
        if !rest.isEmpty { emit(String(decoding: rest, as: UTF8.self)) }
    }
}
