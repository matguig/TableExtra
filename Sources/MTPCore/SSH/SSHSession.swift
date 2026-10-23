import CLibSSH2
import Foundation

/// How the client signs in. With an explicit key: that key, then the password. Without one: the password,
/// ~/.ssh/config IdentityFile keys, ssh-agent, then ~/.ssh/id_ed25519, id_ecdsa and id_rsa.
public struct SSHCredentials: Sendable {
    public var user: String
    /// An explicit key: when set, only this key is offered (like `IdentitiesOnly=yes`), then the password.
    public var privateKeyPath: String?
    public var passphrase: String?
    public var password: String?
    /// IdentityFile entries from ~/.ssh/config, tried before the agent when no explicit key is set.
    public var configIdentityFiles: [String] = []
    /// IdentityAgent from ~/.ssh/config; nil uses SSH_AUTH_SOCK, "none" disables the agent.
    public var identityAgent: String?

    public init(user: String, privateKeyPath: String? = nil, passphrase: String? = nil, password: String? = nil) {
        self.user = user
        self.privateKeyPath = privateKeyPath
        self.passphrase = passphrase
        self.password = password
    }
}

/// The server's key differs from the one TableExtra saved the first time: possible man-in-the-middle.
/// `SSHKnownHosts.shared.forget(host:port:)` accepts the new key on the next connection.
public struct SSHHostKeyChangedError: Error, LocalizedError, Sendable {
    public var host: String
    public var port: Int
    public var savedFingerprint: String
    public var serverFingerprint: String

    public var errorDescription: String? {
        """
        SSH host key for \(host) changed. Saved: \(savedFingerprint), server: \(serverFingerprint). \
        Someone could be intercepting the connection, or the server was reinstalled. \
        If the change is expected, use “Forget Host Key” in the connection settings.
        """
    }
}

/// One libssh2 session over a TCP socket. Not thread-safe: use it from one thread at a time.
final class SSHSession {
    let raw: OpaquePointer
    let socket: Int32
    let host: String
    let port: Int
    private var isClosed = false

    private static let libraryReady: Bool = libssh2_init(0) == 0

    init(host: String, port: Int, timeout: TimeInterval) throws {
        guard Self.libraryReady else { throw DatabaseError("SSH: libssh2 could not be initialised") }
        let fd = try SSHSocket.connect(host: host, port: port, timeout: timeout)
        guard let session = mtp_ssh2_session_init() else {
            Darwin.close(fd)
            throw DatabaseError("SSH: could not create a session")
        }
        raw = session
        socket = fd
        self.host = host
        self.port = port
        libssh2_session_set_blocking(session, 1)
        libssh2_session_set_timeout(session, Int(timeout * 1000))
        if libssh2_session_handshake(session, fd) != 0 {
            let message = lastError
            close()
            throw DatabaseError("SSH handshake with \(host):\(port) failed: \(message)")
        }
    }

    deinit { close() }

    var lastError: String {
        var message: UnsafeMutablePointer<CChar>?
        var length: Int32 = 0
        let code = libssh2_session_last_error(raw, &message, &length, 0)
        guard let message, length > 0 else { return "error \(code)" }
        return String(cString: message)
    }

    var lastErrno: Int32 { libssh2_session_last_errno(raw) }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        libssh2_session_set_blocking(raw, 1)
        libssh2_session_set_timeout(raw, 2000)
        libssh2_session_disconnect_ex(raw, SSH_DISCONNECT_BY_APPLICATION, "Closed by TableExtra", "")
        libssh2_session_free(raw)
        Darwin.close(socket)
    }

    // MARK: Host key

    func hostKey() throws -> (key: SSHHostKey, libssh2Type: Int32) {
        var length = 0
        var type: Int32 = 0
        guard let pointer = libssh2_session_hostkey(raw, &length, &type), length > 0 else {
            throw DatabaseError("SSH: the server did not send a host key")
        }
        return (SSHHostKey(blob: Data(bytes: pointer, count: length)), type)
    }

    /// Accepts a key that matches ~/.ssh/known_hosts or TableExtra's own list; remembers a host seen for the first
    /// time; refuses a key that differs from a saved one (possible man-in-the-middle).
    func verifyHostKey(store: SSHKnownHosts, systemKnownHosts: URL? = SSHSession.defaultKnownHostsFile) throws {
        let (key, type) = try hostKey()
        switch checkKnownHostsFile(systemKnownHosts, key: key, type: type) {
        case .match:
            return
        case .mismatch:
            throw DatabaseError("""
                SSH host key for \(host) does not match ~/.ssh/known_hosts. Someone could be intercepting the connection, \
                or the server was reinstalled. Server key: \(key.type) \(key.fingerprint). \
                If the change is expected, run: ssh-keygen -R \(host)
                """)
        case .notFound:
            break
        }
        if let saved = store.entry(host: host, port: port), saved.type == key.type {
            guard saved.key == key.blob.base64EncodedString() else {
                throw SSHHostKeyChangedError(host: host, port: port, savedFingerprint: saved.fingerprint, serverFingerprint: key.fingerprint)
            }
            return
        }
        store.trust(key, host: host, port: port)
    }

    static var defaultKnownHostsFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/known_hosts")
    }

    private enum KnownHostsResult { case match, mismatch, notFound }

    private func checkKnownHostsFile(_ file: URL?, key: SSHHostKey, type: Int32) -> KnownHostsResult {
        guard let file, FileManager.default.isReadableFile(atPath: file.path), let hosts = libssh2_knownhost_init(raw) else { return .notFound }
        defer { libssh2_knownhost_free(hosts) }
        guard libssh2_knownhost_readfile(hosts, file.path, LIBSSH2_KNOWNHOST_FILE_OPENSSH) >= 0 else { return .notFound }
        var found: UnsafeMutablePointer<libssh2_knownhost>?
        let mask = mtp_ssh2_knownhost_plain_raw() | mtp_ssh2_knownhost_keybits(type)
        let result = key.blob.withUnsafeBytes { bytes in
            libssh2_knownhost_checkp(hosts, host, Int32(port), bytes.baseAddress?.assumingMemoryBound(to: CChar.self), bytes.count, mask, &found)
        }
        switch result {
        case LIBSSH2_KNOWNHOST_CHECK_MATCH: return .match
        case LIBSSH2_KNOWNHOST_CHECK_MISMATCH: return .mismatch
        default: return .notFound
        }
    }

    // MARK: Authentication

    func authenticate(_ credentials: SSHCredentials) throws {
        let user = credentials.user
        guard !user.isEmpty else { throw DatabaseError("SSH: enter the SSH user") }
        let list = libssh2_userauth_list(raw, user, UInt32(user.utf8.count))
        if list == nil, libssh2_userauth_authenticated(raw) != 0 { return }
        let methods = Set((list.map { String(cString: $0) } ?? "").split(separator: ",").map(String.init))
        var tried: [String] = []
        var hints: [String] = []

        func succeeded(_ rc: Int32) throws -> Bool {
            if rc == 0 { return true }
            try failIfDisconnected()
            return false
        }

        // Without an explicit key, a saved password goes first: agents often hold more keys than the server's
        // MaxAuthTries allows, and the server would disconnect before the password is tried.
        let password = credentials.password ?? ""
        let explicitKey = !(credentials.privateKeyPath ?? "").isEmpty
        func tryPassword() throws -> Bool {
            guard !password.isEmpty else { return false }
            if methods.contains("password") {
                tried.append("password")
                if try succeeded(libssh2_userauth_password_ex(raw, user, UInt32(user.utf8.count), password, UInt32(password.utf8.count), nil)) { return true }
            }
            if methods.contains("keyboard-interactive") {
                tried.append("keyboard-interactive")
                if try succeeded(mtp_ssh2_userauth_kbdint_password(raw, user, password)) { return true }
            }
            return false
        }

        if !explicitKey, try tryPassword() { return }
        if methods.contains("publickey") {
            if let path = credentials.privateKeyPath, !path.isEmpty {
                let key = try SSHPrivateKey.load(path)
                if key.isEncrypted && (credentials.passphrase ?? "").isEmpty {
                    hints.append("\(key.displayName) is protected by a passphrase: enter it in the connection settings")
                } else {
                    tried.append("key \(key.displayName)")
                    if try succeeded(signIn(user: user, key: key, passphrase: credentials.passphrase)) { return }
                    if key.isEncrypted { hints.append("check the passphrase of \(key.displayName)") }
                }
            } else {
                var offered = Set<String>()
                for path in credentials.configIdentityFiles where offered.insert(path).inserted {
                    guard let key = try? SSHPrivateKey.load(path), !key.isEncrypted else { continue }
                    tried.append("key \(key.displayName)")
                    if try succeeded(signIn(user: user, key: key, passphrase: nil)) { return }
                }
                if try signInWithAgent(user: user, socketPath: credentials.identityAgent, tried: &tried) { return }
                for name in ["id_ed25519", "id_ecdsa", "id_rsa"] {
                    let path = "~/.ssh/\(name)"
                    guard offered.insert((path as NSString).expandingTildeInPath).inserted,
                          let key = try? SSHPrivateKey.load(path), !key.isEncrypted else { continue }
                    tried.append("key \(key.displayName)")
                    if try succeeded(signIn(user: user, key: key, passphrase: nil)) { return }
                }
            }
        }

        if explicitKey, try tryPassword() { return }
        if password.isEmpty && methods.contains("password") && !methods.contains("publickey") {
            hints.append("the server only accepts a password: enter the SSH password")
        }

        var message = "SSH authentication failed for \(user)@\(host)."
        message += tried.isEmpty ? " Nothing could be tried." : " Tried: \(tried.joined(separator: ", "))."
        if !methods.isEmpty { message += " The server accepts: \(methods.sorted().joined(separator: ", "))." }
        if !hints.isEmpty { message += " " + hints.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: ". ") + "." }
        throw DatabaseError(message)
    }

    private func signIn(user: String, key: SSHPrivateKey, passphrase: String?) -> Int32 {
        key.data.withUnsafeBytes { bytes in
            libssh2_userauth_publickey_frommemory(raw, user, user.utf8.count, nil, 0,
                                                  bytes.baseAddress?.assumingMemoryBound(to: CChar.self), bytes.count, passphrase ?? "")
        }
    }

    /// Offers up to five agent identities (servers usually stop after six attempts).
    private func signInWithAgent(user: String, socketPath: String?, tried: inout [String]) throws -> Bool {
        if socketPath == "none" { return false }
        let path = socketPath == nil || socketPath == "SSH_AUTH_SOCK" ? ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] : socketPath
        guard let path, !path.isEmpty, FileManager.default.fileExists(atPath: path), let agent = libssh2_agent_init(raw) else { return false }
        defer { libssh2_agent_free(agent) }
        libssh2_agent_set_identity_path(agent, path)
        guard libssh2_agent_connect(agent) == 0 else { return false }
        defer { libssh2_agent_disconnect(agent) }
        guard libssh2_agent_list_identities(agent) == 0 else { return false }
        var previous: UnsafeMutablePointer<libssh2_agent_publickey>?
        var attempts = 0
        while attempts < 5 {
            var identity: UnsafeMutablePointer<libssh2_agent_publickey>?
            guard libssh2_agent_get_identity(agent, &identity, previous) == 0, let identity else { break }
            previous = identity
            attempts += 1
            let comment = identity.pointee.comment.map { String(cString: $0) } ?? ""
            tried.append("ssh-agent key\(comment.isEmpty ? "" : " " + comment)")
            if libssh2_agent_userauth(agent, user, identity) == 0 { return true }
            try failIfDisconnected()
        }
        return false
    }

    private func failIfDisconnected() throws {
        switch lastErrno {
        case LIBSSH2_ERROR_SOCKET_DISCONNECT, LIBSSH2_ERROR_SOCKET_SEND, LIBSSH2_ERROR_SOCKET_RECV, LIBSSH2_ERROR_SOCKET_TIMEOUT, LIBSSH2_ERROR_TIMEOUT:
            throw DatabaseError("SSH: the server closed the connection during sign-in (\(lastError)). "
                                + "Servers limit the number of attempts: choose the right private key in the connection settings.")
        default:
            return
        }
    }
}

/// A private key file read into memory (OpenSSH, PEM or PKCS#8; RSA, ECDSA or Ed25519).
struct SSHPrivateKey {
    var data: Data
    var displayName: String
    var isEncrypted: Bool

    static func load(_ path: String) throws -> SSHPrivateKey {
        let expanded = (path as NSString).expandingTildeInPath
        let name = (path as NSString).lastPathComponent
        guard let data = FileManager.default.contents(atPath: expanded) else {
            throw DatabaseError("SSH: cannot read the private key \(path)")
        }
        let text = String(decoding: data, as: UTF8.self)
        if text.hasPrefix("PuTTY-User-Key-File") {
            throw DatabaseError("SSH: \(name) is a PuTTY key. Convert it with: puttygen \(name) -O private-openssh -o \(name).pem")
        }
        guard text.contains("PRIVATE KEY-----") else {
            throw DatabaseError("SSH: \(name) is not a private key (choose the file without .pub)")
        }
        return SSHPrivateKey(data: data, displayName: name, isEncrypted: isEncrypted(text))
    }

    /// PEM `Proc-Type: 4,ENCRYPTED`, PKCS#8 `ENCRYPTED PRIVATE KEY`, or an OpenSSH key whose cipher is not "none".
    static func isEncrypted(_ text: String) -> Bool {
        if text.contains("ENCRYPTED") { return true }
        guard text.contains("BEGIN OPENSSH PRIVATE KEY") else { return false }
        let body = text.components(separatedBy: .newlines).filter { !$0.hasPrefix("-----") }.joined()
        guard let bytes = Data(base64Encoded: body) else { return false }
        let magic = Data("openssh-key-v1\0".utf8)
        guard bytes.count > magic.count + 4, bytes.prefix(magic.count) == magic else { return false }
        let start = magic.count
        let length = bytes[start..<start + 4].reduce(0) { $0 << 8 | Int($1) }
        guard bytes.count >= start + 4 + length else { return false }
        return String(decoding: bytes[(start + 4)..<(start + 4 + length)], as: UTF8.self) != "none"
    }
}

enum SSHSocket {
    /// TCP connection with a timeout, trying every address the name resolves to.
    static func connect(host: String, port: Int, timeout: TimeInterval) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var info: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &info)
        guard rc == 0, let first = info else {
            throw DatabaseError("SSH: cannot resolve \(host) (\(String(cString: gai_strerror(rc))))")
        }
        defer { freeaddrinfo(first) }
        var lastError = "no address"
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let ai = cursor {
            cursor = ai.pointee.ai_next
            let fd = Darwin.socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
            guard fd >= 0 else { continue }
            let flags = fcntl(fd, F_GETFL)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            var ok = Darwin.connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0
            if !ok && errno == EINPROGRESS {
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                if poll(&pfd, 1, Int32(timeout * 1000)) == 1 {
                    var soError: Int32 = 0
                    var len = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len)
                    ok = soError == 0
                    if !ok { lastError = String(cString: strerror(soError)) }
                } else {
                    lastError = "timed out after \(Int(timeout))s"
                }
            } else if !ok {
                lastError = String(cString: strerror(errno))
            }
            guard ok else { Darwin.close(fd); continue }
            _ = fcntl(fd, F_SETFL, flags)
            configure(fd)
            return fd
        }
        throw DatabaseError("SSH: cannot connect to \(host):\(port) (\(lastError))")
    }

    static func configure(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
    }
}
