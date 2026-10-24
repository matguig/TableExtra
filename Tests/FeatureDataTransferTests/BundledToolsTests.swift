import MTPCore
import XCTest
@testable import FeatureDataTransfer

/// In-process gunzip, the stdin feeder, and the pg tools shipped in the app bundle.
final class BundledToolsTests: XCTestCase {
    func gzip(_ text: String, in dir: URL, name: String) throws -> URL {
        let plain = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: plain)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        p.arguments = ["-f", plain.path]
        try p.run()
        p.waitUntilExit()
        return dir.appendingPathComponent(name + ".gz")
    }

    /// Decompresses `file` through a pipe, as psql receives it.
    func gunzip(_ file: URL) throws -> Data {
        let pipe = Pipe()
        nonisolated(unsafe) var data = Data()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        var failure: Error?
        do { try Gunzip.stream(file, to: pipe.fileHandleForWriting.fileDescriptor) } catch { failure = error }
        try pipe.fileHandleForWriting.close()
        done.wait()
        if let failure { throw failure }
        return data
    }

    func testGunzipSingleAndConcatenatedMembers() throws {
        let dir = try tempDir()
        // Larger than one 64 KiB chunk on both sides.
        let big = (0..<20_000).map { "INSERT INTO t VALUES (\($0), 'row \($0)');" }.joined(separator: "\n") + "\n"
        let a = try gzip(big, in: dir, name: "a.sql")
        XCTAssertEqual(String(decoding: try gunzip(a), as: UTF8.self), big)

        let b = try gzip("SELECT 2;\n", in: dir, name: "b.sql")
        let both = dir.appendingPathComponent("both.sql.gz")
        try (try Data(contentsOf: a) + Data(contentsOf: b)).write(to: both)
        XCTAssertEqual(String(decoding: try gunzip(both), as: UTF8.self), big + "SELECT 2;\n")
    }

    func testGunzipRejectsTruncatedAndCorruptFiles() throws {
        let dir = try tempDir()
        let text = (0..<5_000).map { "line \($0)" }.joined(separator: "\n")
        let gz = try Data(contentsOf: gzip(text, in: dir, name: "x.sql"))
        let truncated = dir.appendingPathComponent("truncated.gz")
        try gz.prefix(gz.count / 2).write(to: truncated)
        XCTAssertThrowsError(try gunzip(truncated)) { XCTAssertTrue($0.localizedDescription.contains("unexpected end"), $0.localizedDescription) }

        var corrupt = gz
        for i in 20..<60 { corrupt[i] ^= 0xFF }
        let bad = dir.appendingPathComponent("bad.gz")
        try corrupt.write(to: bad)
        XCTAssertThrowsError(try gunzip(bad))
    }

    func testFeederPipesIntoTool() async throws {
        let dir = try tempDir()
        let gz = try gzip("one\ntwo\nthree\n", in: dir, name: "lines.txt")
        let feeder = ProcessRunner.StdinFeeder(label: "gunzip -c \(gz.path)") { fd in try Gunzip.stream(gz, to: fd) }
        let runner = ProcessRunner(executable: URL(fileURLWithPath: "/usr/bin/wc"), arguments: ["-l"], environment: [:], stdinFeeder: feeder)
        XCTAssertEqual(runner.commandLine, "gunzip -c \(gz.path) | /usr/bin/wc -l")
        let lines = LockedArray<String>()
        let outcome = try await runner.run { lines.append($1) }
        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(lines.values.map { $0.trimmingCharacters(in: .whitespaces) }, ["3"])
    }

    func testFeederFailureFailsTheRun() async throws {
        let feeder = ProcessRunner.StdinFeeder(label: "broken") { _ in throw Gunzip.Failure(errorDescription: "gunzip: boom") }
        let runner = ProcessRunner(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], environment: [:], stdinFeeder: feeder)
        let lines = LockedArray<String>()
        let outcome = try await runner.run { lines.append($1) }
        XCTAssertFalse(outcome.succeeded, "cat exits 0 but its input was cut short")
        XCTAssertEqual(lines.values, ["gunzip: boom"])
    }

    func testFeederStopsWhenToolExitsEarly() async throws {
        // `head -1` exits after the first line; the feeder must get EPIPE (not SIGPIPE) and return.
        let dir = try tempDir()
        let gz = try gzip((0..<200_000).map { "line \($0)" }.joined(separator: "\n"), in: dir, name: "many.txt")
        let feeder = ProcessRunner.StdinFeeder(label: "gunzip") { fd in try Gunzip.stream(gz, to: fd) }
        let runner = ProcessRunner(executable: URL(fileURLWithPath: "/usr/bin/head"), arguments: ["-1"], environment: [:], stdinFeeder: feeder)
        let lines = LockedArray<String>()
        let outcome = try await runner.run { lines.append($1) }
        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(lines.values, ["line 0"])
    }

    func testBundledToolsAreFoundFirst() throws {
        let dir = try tempDir()
        let tool = dir.appendingPathComponent("pg_dump")
        try "#!/bin/sh\necho 'pg_dump (PostgreSQL) 99.1'\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        let saved = PGToolLocator.bundledDirectory
        PGToolLocator.bundledDirectory = dir.path
        defer { PGToolLocator.bundledDirectory = saved }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "bundled-tools-\(UUID().uuidString)"))

        XCTAssertEqual(PGToolLocator.searchDirectories(defaults: defaults).first, dir.path)
        let found = PGToolLocator.candidates("pg_dump", defaults: defaults)
        let first = try XCTUnwrap(found.first)
        XCTAssertTrue(first.isBundled)
        XCTAssertEqual(first.major, 99)
        XCTAssertEqual(first.displayName, "pg_dump 99.1 — built-in")
        XCTAssertFalse(found.dropFirst().contains { $0.isBundled })
        // The built-in copy wins over an installed one of the server's own version...
        let local = PGTool(name: "pg_dump", url: URL(fileURLWithPath: "/opt/pg/bin/pg_dump"), version: "14.15", major: 14)
        XCTAssertEqual(PGToolLocator.preferred("pg_dump", serverMajor: 14, among: found + [local], defaults: defaults)?.url, tool)
        // ...but not when the server is newer than it.
        let newer = PGTool(name: "pg_dump", url: URL(fileURLWithPath: "/opt/pg100/bin/pg_dump"), version: "100.1", major: 100)
        XCTAssertEqual(PGToolLocator.preferred("pg_dump", serverMajor: 100, among: found + [newer], defaults: defaults)?.url, newer.url)
    }
}

/// Plain scripts for servers older than PostgreSQL 17.
final class ScriptFeedTests: XCTestCase {
    let script = "--\n-- PostgreSQL database dump\n--\nSET statement_timeout = 0;\nSET transaction_timeout = 0;\nSET client_encoding = 'UTF8';\n"
        + "CREATE TABLE t (note text);\nINSERT INTO t VALUES ('SET transaction_timeout = 0;');\n"

    func feed(_ file: URL, gzip: Bool, skip: Bool) async throws -> String {
        let feeder = ProcessRunner.StdinFeeder(label: ScriptFeed.label(file, gzip: gzip, skipTransactionTimeout: skip)) { fd in
            try ScriptFeed.stream(file, gzip: gzip, skipTransactionTimeout: skip, to: fd)
        }
        let runner = ProcessRunner(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], environment: [:], stdinFeeder: feeder)
        let lines = LockedArray<String>()
        let outcome = try await runner.run { lines.append($1) }
        XCTAssertTrue(outcome.succeeded)
        return lines.values.joined(separator: "\n") + "\n"
    }

    func testDropsOnlyTheHeaderLine() async throws {
        let dir = try tempDir()
        let plain = dir.appendingPathComponent("dump.sql")
        try Data(script.utf8).write(to: plain)
        let expected = script.replacingOccurrences(of: "SET transaction_timeout = 0;\nSET client", with: "SET client")
        let skipped = try await feed(plain, gzip: false, skip: true)
        XCTAssertEqual(skipped, expected, "the INSERT keeps its literal")
        let kept = try await feed(plain, gzip: false, skip: false)
        XCTAssertEqual(kept, script)

        let gz = try BundledToolsTests().gzip(script, in: dir, name: "dump2.sql")
        let fromGzip = try await feed(gz, gzip: true, skip: true)
        XCTAssertEqual(fromGzip, expected)
        XCTAssertEqual(ScriptFeed.label(gz, gzip: true, skipTransactionTimeout: true),
                       "gunzip -c \(gz.path) | grep -vx 'SET transaction_timeout = 0;'")
    }

    func testLargeScriptPassesThroughUnchanged() async throws {
        let dir = try tempDir()
        let body = (0..<30_000).map { "INSERT INTO t VALUES (\($0));" }.joined(separator: "\n") + "\n"
        let plain = dir.appendingPathComponent("big.sql")
        try Data(("SET transaction_timeout = 0;\n" + body).utf8).write(to: plain)
        let out = try await feed(plain, gzip: false, skip: true)
        XCTAssertEqual(out, body)
    }

    func testPsqlRunnerUsesFeedOnlyWhenNeeded() throws {
        let psql = PGTool(name: "psql", url: URL(fileURLWithPath: "/usr/bin/true"), version: "18.6", major: 18)
        let config = ConnectionConfig(name: "t", driver: .postgres, host: "127.0.0.1")
        let target = PGConnectionTarget(config: config, password: nil)
        let file = URL(fileURLWithPath: "/tmp/x.sql")
        let modern = BackupEngine.psql(tool: psql, target: target, options: PGRestoreOptions(), input: file, format: .plain, serverMajor: 17)
        XCTAssertNil(modern.stdinFeeder)
        XCTAssertTrue(modern.arguments.contains("--file=/tmp/x.sql"))
        let old = BackupEngine.psql(tool: psql, target: target, options: PGRestoreOptions(), input: file, format: .plain, serverMajor: 14)
        XCTAssertNotNil(old.stdinFeeder)
        XCTAssertFalse(old.arguments.contains("--file=/tmp/x.sql"))
        XCTAssertTrue(old.commandLine.hasPrefix("cat /tmp/x.sql | grep -vx"))
    }
}
