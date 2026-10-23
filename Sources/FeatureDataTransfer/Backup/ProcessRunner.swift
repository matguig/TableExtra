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
    /// Optional producer piped into stdin (e.g. gunzip for compressed scripts).
    public let stdinProducer: (executable: URL, arguments: [String])?

    private let lock = NSLock()
    private var process: Process?
    private var producer: Process?
    private var terminated = false

    public init(executable: URL, arguments: [String], environment: [String: String], stdinProducer: (executable: URL, arguments: [String])? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.stdinProducer = stdinProducer
    }

    /// Shell-like rendering for the log; values of `--password`-like flags never appear since secrets go through the environment.
    public var commandLine: String {
        var parts = [executable.path] + arguments
        parts = parts.map { $0.contains(where: { " \"'$`\\".contains($0) }) ? "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" : $0 }
        let cmd = parts.joined(separator: " ")
        guard let p = stdinProducer else { return cmd }
        return ([p.executable.path] + p.arguments).joined(separator: " ") + " | " + cmd
    }

    public func run(onLine: @escaping @Sendable (Stream, String) -> Void) async throws -> Outcome {
        let p = Process()
        p.executableURL = executable
        p.arguments = arguments
        p.environment = environment
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err

        let feederErr = Pipe()
        let feeder: Process? = stdinProducer.map { prod in
            let f = Process()
            f.executableURL = prod.executable
            f.arguments = prod.arguments
            let link = Pipe()
            f.standardOutput = link
            f.standardError = feederErr
            p.standardInput = link
            return f
        }
        if feeder == nil { p.standardInput = FileHandle.nullDevice }

        let outLines = LineSplitter { onLine(.stdout, $0) }
        let errLines = LineSplitter { onLine(.stderr, $0) }
        out.fileHandleForReading.readabilityHandler = { h in outLines.append(h.availableData) }
        err.fileHandleForReading.readabilityHandler = { h in errLines.append(h.availableData) }
        if feeder != nil {
            feederErr.fileHandleForReading.readabilityHandler = { h in errLines.append(h.availableData) }
        }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Outcome, Error>) in
            p.terminationHandler = { [weak self] proc in
                if let f = feeder, f.isRunning { f.terminate() }
                feederErr.fileHandleForReading.readabilityHandler = nil
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                outLines.append(out.fileHandleForReading.readDataToEndOfFile())
                errLines.append(err.fileHandleForReading.readDataToEndOfFile())
                outLines.flush()
                errLines.flush()
                let killed = self?.wasTerminated ?? false
                cont.resume(returning: Outcome(status: proc.terminationStatus, wasTerminated: killed || proc.terminationReason == .uncaughtSignal))
            }
            do {
                lock.lock()
                process = p
                producer = feeder
                let alreadyCancelled = terminated
                lock.unlock()
                if alreadyCancelled {
                    p.terminationHandler = nil
                    cont.resume(returning: Outcome(status: -1, wasTerminated: true))
                    return
                }
                try feeder?.run()
                try p.run()
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

    public func terminate() {
        lock.lock()
        terminated = true
        let p = process, f = producer
        lock.unlock()
        if let f, f.isRunning { f.terminate() }
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
