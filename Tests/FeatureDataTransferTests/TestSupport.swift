import MTPCore
import XCTest

/// Scratch folder for test files (MTP_TEST_SCRATCH, else the system temp directory).
func scratchRoot() -> URL {
    let base = ProcessInfo.processInfo.environment["MTP_TEST_SCRATCH"] ?? NSTemporaryDirectory()
    return URL(fileURLWithPath: base, isDirectory: true)
}

extension XCTestCase {
    func tempDir(keep: Bool = false) throws -> URL {
        let url = scratchRoot().appendingPathComponent("mtp-dt-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if !keep { addTeardownBlock { try? FileManager.default.removeItem(at: url) } }
        return url
    }

    /// MTP_TEST_PG="host:port:user:password:db"; skips the test when unset.
    func pgSpec() throws -> (config: ConnectionConfig, password: String) {
        guard let spec = ProcessInfo.processInfo.environment["MTP_TEST_PG"] else { throw XCTSkip("MTP_TEST_PG not set") }
        let p = spec.split(separator: ":").map(String.init)
        let c = ConnectionConfig(name: "test", driver: .postgres, host: p[0], port: Int(p[1]), user: p[2], database: p[4], sslMode: .disable)
        return (c, p[3])
    }

    func pgClient(database: String? = nil) throws -> DBClient {
        var (c, pw) = try pgSpec()
        if let database { c.database = database }
        return DBClient(config: c, secrets: ConnectionSecrets(password: pw))
    }
}
