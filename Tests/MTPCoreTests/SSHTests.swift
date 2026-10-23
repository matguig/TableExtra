import XCTest
@testable import MTPCore

final class SSHConfigFileTests: XCTestCase {
    let config = """
        # comment
        Host bastion bastion-*
            HostName %h.example.com
            User deploy
            Port 2222
            IdentityFile ~/.ssh/deploy_ed25519
            IdentityFile %d/.ssh/second

        Host jump-only
            ProxyJump bastion

        Host *.internal !secret.internal
            User internal

        Host *
            User fallback
            IdentityAgent "~/Library/Group Containers/agent.sock"
            Port 22
        """

    func testFirstValueWinsAndIdentityFilesAccumulate() {
        let s = SSHConfigFile.settings(for: "bastion", in: config, home: "/Users/me")
        XCTAssertEqual(s.hostName, "bastion.example.com")
        XCTAssertEqual(s.user, "deploy")
        XCTAssertEqual(s.port, 2222)
        XCTAssertEqual(s.identityFiles, ["/Users/me/.ssh/deploy_ed25519", "/Users/me/.ssh/second"])
        XCTAssertEqual(s.identityAgent, "/Users/me/Library/Group Containers/agent.sock")
        XCTAssertNil(s.proxy)
    }

    func testPatternsAndNegation() {
        XCTAssertEqual(SSHConfigFile.settings(for: "bastion-eu", in: config, home: "/h").user, "deploy")
        XCTAssertEqual(SSHConfigFile.settings(for: "db.internal", in: config, home: "/h").user, "internal")
        XCTAssertEqual(SSHConfigFile.settings(for: "secret.internal", in: config, home: "/h").user, "fallback")
        XCTAssertEqual(SSHConfigFile.settings(for: "other", in: config, home: "/h").port, 22)
        XCTAssertEqual(SSHConfigFile.settings(for: "jump-only", in: config, home: "/h").proxy, "bastion")
    }

    func testEndpointAppliesConfigButFormWins() throws {
        var ssh = SSHConfig()
        ssh.host = "bastion"
        let file = SSHConfigFile.settings(for: "bastion", in: config, home: "/h")
        var e = try SSHTunnel.endpoint(for: ssh, secrets: ConnectionSecrets(sshPassword: "pw"), settings: file)
        XCTAssertEqual(e.host, "bastion.example.com")
        XCTAssertEqual(e.port, 2222)
        XCTAssertEqual(e.credentials.user, "deploy")
        XCTAssertEqual(e.credentials.password, "pw")
        XCTAssertNil(e.credentials.privateKeyPath)

        ssh.user = "admin"
        ssh.port = 2200
        ssh.privateKeyPath = "~/.ssh/other"
        e = try SSHTunnel.endpoint(for: ssh, secrets: ConnectionSecrets(), settings: file)
        XCTAssertEqual(e.credentials.user, "admin")
        XCTAssertEqual(e.port, 2200)
        XCTAssertEqual(e.credentials.privateKeyPath, "~/.ssh/other")

        ssh.host = "jump-only"
        XCTAssertThrowsError(try SSHTunnel.endpoint(for: ssh, secrets: ConnectionSecrets(),
                                                    settings: SSHConfigFile.settings(for: "jump-only", in: config, home: "/h")))
    }

    func testHostKeyFingerprintAndStore() throws {
        // ssh-ed25519 blob: string "ssh-ed25519" + string(32 bytes).
        var blob = Data([0, 0, 0, 11]) + Data("ssh-ed25519".utf8) + Data([0, 0, 0, 32])
        blob += Data(repeating: 7, count: 32)
        let key = SSHHostKey(blob: blob)
        XCTAssertEqual(key.type, "ssh-ed25519")
        XCTAssertTrue(key.fingerprint.hasPrefix("SHA256:"))
        XCTAssertFalse(key.fingerprint.hasSuffix("="))

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kh-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = SSHKnownHosts(file: file)
        XCTAssertNil(store.entry(host: "Bastion", port: 2222))
        store.trust(key, host: "Bastion", port: 2222)
        XCTAssertEqual(SSHKnownHosts(file: file).entry(host: "bastion", port: 2222)?.fingerprint, key.fingerprint)
        XCTAssertNil(store.entry(host: "bastion", port: 22))
        XCTAssertTrue(store.forget(host: "bastion", port: 2222))
        XCTAssertNil(store.entry(host: "bastion", port: 2222))
    }

    func testEncryptedKeyDetection() {
        let pem = "-----BEGIN RSA PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED\nDEK-Info: AES-128-CBC,00\n\nAAAA\n-----END RSA PRIVATE KEY-----\n"
        XCTAssertTrue(SSHPrivateKey.isEncrypted(pem))
        func openSSH(cipher: String) -> String {
            var bytes = Data("openssh-key-v1\0".utf8)
            bytes += Data([0, 0, 0, UInt8(cipher.utf8.count)]) + Data(cipher.utf8) + Data(repeating: 0, count: 16)
            return "-----BEGIN OPENSSH PRIVATE KEY-----\n\(bytes.base64EncodedString())\n-----END OPENSSH PRIVATE KEY-----\n"
        }
        XCTAssertFalse(SSHPrivateKey.isEncrypted(openSSH(cipher: "none")))
        XCTAssertTrue(SSHPrivateKey.isEncrypted(openSSH(cipher: "aes256-ctr")))
    }
}

/// Runs against a disposable sshd that can forward to the test PostgreSQL:
/// MTP_TEST_SSH="host:port:user:/dir/with/keys" (ed25519, rsa_pem, rsa_openssh, ecdsa, ed25519_enc, rsa_pem_enc,
/// unauthorized; encrypted keys use the passphrase "secret-pass") and MTP_TEST_PG="host:port:user:password:db".
final class SSHTunnelIntegrationTests: XCTestCase {
    struct Env {
        var ssh: SSHConfig
        var keys: String
        var pg: [String]
    }

    func env() throws -> Env {
        guard let spec = ProcessInfo.processInfo.environment["MTP_TEST_SSH"],
              let pgSpec = ProcessInfo.processInfo.environment["MTP_TEST_PG"] else { throw XCTSkip("MTP_TEST_SSH / MTP_TEST_PG not set") }
        let p = spec.split(separator: ":").map(String.init)
        var ssh = SSHConfig()
        ssh.enabled = true
        ssh.host = p[0]
        ssh.port = Int(p[1]) ?? 22
        ssh.user = p[2]
        return Env(ssh: ssh, keys: p[3], pg: pgSpec.split(separator: ":").map(String.init))
    }

    func tempStore() -> SSHKnownHosts {
        SSHKnownHosts(file: FileManager.default.temporaryDirectory.appendingPathComponent("kh-\(UUID().uuidString).json"))
    }

    func tunnel(_ env: Env, key: String?, passphrase: String? = nil, password: String? = nil, store: SSHKnownHosts? = nil) -> SSHTunnel {
        var ssh = env.ssh
        ssh.privateKeyPath = key.map { "\(env.keys)/\($0)" } ?? ""
        return SSHTunnel(ssh: ssh, secrets: ConnectionSecrets(sshPassword: password, sshKeyPassphrase: passphrase),
                         remoteHost: env.pg[0], remotePort: Int(env.pg[1])!, knownHosts: store ?? tempStore())
    }

    func client(_ env: Env, port: Int) -> DBClient {
        let c = ConnectionConfig(name: "via-ssh", driver: .postgres, host: "127.0.0.1", port: port, user: env.pg[2], database: env.pg[4], sslMode: .disable)
        return DBClient(config: c, secrets: ConnectionSecrets(password: env.pg[3]))
    }

    func testEveryKeyTypeForwardsQueries() async throws {
        let env = try env()
        for (key, passphrase) in [("ed25519", nil), ("rsa_pem", nil), ("rsa_openssh", nil), ("ecdsa", nil),
                                  ("ed25519_enc", "secret-pass"), ("rsa_pem_enc", "secret-pass")] as [(String, String?)] {
            let t = tunnel(env, key: key, passphrase: passphrase)
            try t.start()
            let db = client(env, port: t.localPort)
            let r = try await db.query("SELECT 'ok via ' || $1", [key])
            XCTAssertEqual(r.rows.first?.first, "ok via \(key)", key)
            db.close()
            t.stop()
        }
    }

    func testEncryptedKeyWithoutPassphraseExplainsWhy() throws {
        let env = try env()
        XCTAssertThrowsError(try tunnel(env, key: "ed25519_enc").start()) { error in
            XCTAssertTrue(error.localizedDescription.contains("passphrase"), error.localizedDescription)
        }
        XCTAssertThrowsError(try tunnel(env, key: "ed25519_enc", passphrase: "wrong").start()) { error in
            XCTAssertTrue(error.localizedDescription.contains("SSH authentication failed"), error.localizedDescription)
        }
    }

    func testUnauthorizedKeyFails() throws {
        let env = try env()
        XCTAssertThrowsError(try tunnel(env, key: "unauthorized").start()) { error in
            XCTAssertTrue(error.localizedDescription.contains("Tried: key unauthorized"), error.localizedDescription)
        }
    }

    func testHostKeyIsSavedThenEnforced() throws {
        let env = try env()
        let store = tempStore()
        let t = tunnel(env, key: "ed25519", store: store)
        try t.start()
        t.stop()
        let saved = try XCTUnwrap(store.entry(host: env.ssh.host, port: env.ssh.port))
        XCTAssertEqual(saved.type, "ssh-ed25519")

        // Same type, different key: refused.
        var blob = Data([0, 0, 0, 11]) + Data("ssh-ed25519".utf8) + Data([0, 0, 0, 32])
        blob += Data(repeating: 1, count: 32)
        store.trust(SSHHostKey(blob: blob), host: env.ssh.host, port: env.ssh.port)
        XCTAssertThrowsError(try tunnel(env, key: "ed25519", store: store).start()) { error in
            XCTAssertTrue(error is SSHHostKeyChangedError, "\(error)")
        }
        store.forget(host: env.ssh.host, port: env.ssh.port)
        let again = tunnel(env, key: "ed25519", store: store)
        XCTAssertNoThrow(try again.start())
        again.stop()
    }

    func testLargeResultsAndParallelConnections() async throws {
        let env = try env()
        let t = tunnel(env, key: "ed25519")
        try t.start()
        defer { t.stop() }
        let big = client(env, port: t.localPort)
        let r = try await big.query("SELECT g, repeat('x', 200) FROM generate_series(1, 100000) g", maxRows: 200_000)
        XCTAssertEqual(r.rows.count, 100_000)
        XCTAssertEqual(r.rows.last?.first, "100000")
        big.close()

        try await withThrowingTaskGroup(of: String?.self) { group in
            for i in 0..<6 {
                group.addTask {
                    let db = self.client(env, port: t.localPort)
                    defer { db.close() }
                    return try await db.query("SELECT pg_sleep(0.2)::text || '\(i)'").rows.first?.first ?? nil
                }
            }
            var results: [String] = []
            for try await r in group { if let r { results.append(r) } }
            XCTAssertEqual(results.sorted(), (0..<6).map { "\($0)" })
        }
    }

    func testRestartKeepsTheLocalPort() throws {
        let env = try env()
        let t = tunnel(env, key: "ed25519")
        try t.start()
        let port = t.localPort
        XCTAssertTrue(t.isRunning)
        t.stop()
        XCTAssertFalse(t.isRunning)
        try t.start()
        XCTAssertEqual(t.localPort, port)
        t.stop()
    }

    /// Password and keyboard-interactive sign-in: MTP_TEST_SSH_PASSWORD="host:port:user:password" (no forwarding needed).
    func testPasswordSignIn() throws {
        guard let spec = ProcessInfo.processInfo.environment["MTP_TEST_SSH_PASSWORD"] else { throw XCTSkip("MTP_TEST_SSH_PASSWORD not set") }
        let p = spec.split(separator: ":").map(String.init)
        var ssh = SSHConfig()
        ssh.host = p[0]
        ssh.port = Int(p[1])!
        ssh.user = p[2]
        let ok = SSHTunnel(ssh: ssh, secrets: ConnectionSecrets(sshPassword: p[3]), remoteHost: "127.0.0.1", remotePort: 5432, knownHosts: tempStore())
        XCTAssertNoThrow(try ok.start())
        ok.stop()
        // An explicit key keeps the agent and ~/.ssh keys out of the attempt.
        if let keys = try? env().keys { ssh.privateKeyPath = "\(keys)/unauthorized" }
        let wrong = SSHTunnel(ssh: ssh, secrets: ConnectionSecrets(sshPassword: "nope"), remoteHost: "127.0.0.1", remotePort: 5432, knownHosts: tempStore())
        XCTAssertThrowsError(try wrong.start()) { error in
            XCTAssertTrue(error.localizedDescription.contains("Tried:") && error.localizedDescription.contains("password"), error.localizedDescription)
        }
    }

    /// Kills the sshd session (children of MTP_TEST_SSHD_PID) under a live DBClient: the next query reopens the tunnel.
    func testReconnectsAfterTheSSHConnectionDrops() async throws {
        let env = try env()
        guard let sshd = ProcessInfo.processInfo.environment["MTP_TEST_SSHD_PID"] else { throw XCTSkip("MTP_TEST_SSHD_PID not set") }
        var ssh = env.ssh
        ssh.privateKeyPath = "\(env.keys)/ed25519"
        let c = ConnectionConfig(name: "ssh", driver: .postgres, host: env.pg[0], port: Int(env.pg[1]), user: env.pg[2],
                                 database: env.pg[4], sslMode: .disable, ssh: ssh)
        let db = DBClient(config: c, secrets: ConnectionSecrets(password: env.pg[3]))
        _ = try await db.query("SELECT 1")
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        kill.arguments = ["-P", sshd]
        try kill.run()
        kill.waitUntilExit()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        // The first query may still fail on the dead connection; the client must recover by the second.
        let first = try? await db.query("SELECT 'after drop'")
        let second = try await db.query("SELECT 'after drop'")
        XCTAssertEqual((first ?? second).rows.first?.first, "after drop")
        db.close()
    }

    /// The DBClient path: SSH settings on the connection itself.
    func testDBClientOverSSH() async throws {
        let env = try env()
        var ssh = env.ssh
        ssh.privateKeyPath = "\(env.keys)/ecdsa"
        let c = ConnectionConfig(name: "ssh", driver: .postgres, host: env.pg[0], port: Int(env.pg[1]), user: env.pg[2],
                                 database: env.pg[4], sslMode: .disable, ssh: ssh)
        let db = DBClient(config: c, secrets: ConnectionSecrets(password: env.pg[3]))
        let info = try await db.connect()
        XCTAssertEqual(info.product, "PostgreSQL")
        let answer = try await db.query("SELECT 41 + 1")
        XCTAssertEqual(answer.rows.first?.first, "42")
        db.close()
    }
}
