import XCTest
import MTPCore
import MTPUIKit
@testable import FeatureInsights

/// MTP_TEST_PG="host:port:user:password:db" (the disposable test server only).
enum TestDB {
    static func pgSpec() throws -> (config: ConnectionConfig, secrets: ConnectionSecrets) {
        guard let spec = ProcessInfo.processInfo.environment["MTP_TEST_PG"], !spec.isEmpty else {
            throw XCTSkip("MTP_TEST_PG not set")
        }
        let p = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard p.count == 5 else { throw XCTSkip("MTP_TEST_PG must be host:port:user:password:db") }
        let c = ConnectionConfig(name: "insights-test", driver: .postgres, host: p[0], port: Int(p[1]), user: p[2],
                                 database: p[4], sslMode: .disable)
        return (c, ConnectionSecrets(password: p[3]))
    }

    static func pgClient(label: String = "test") throws -> DBClient {
        let s = try pgSpec()
        return DBClient(config: s.config, secrets: s.secrets, label: label)
    }

    @MainActor
    static func pgContext() async throws -> StandaloneWorkspaceContext {
        let s = try pgSpec()
        let ctx = StandaloneWorkspaceContext(connection: s.config, secrets: s.secrets)
        try await ctx.prepare()
        return ctx
    }

    @MainActor
    static func sqliteContext(path: String) async throws -> StandaloneWorkspaceContext {
        let c = ConnectionConfig(name: "lite", driver: .sqlite, filePath: path)
        let ctx = StandaloneWorkspaceContext(connection: c, secrets: ConnectionSecrets())
        try await ctx.prepare()
        return ctx
    }

    /// Polls `condition` on the main actor every 50 ms.
    @MainActor
    static func wait(timeout: TimeInterval = 15, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }
}
