import CLibSSH2
import Foundation

/// Local port forward over a built-in SSH client (libssh2), so no `ssh` process is launched.
/// Signs in with the connection's private key, a password, ssh-agent or the default keys in ~/.ssh, and applies
/// HostName / User / Port / IdentityFile / IdentityAgent from ~/.ssh/config. ProxyJump is not supported.
public final class SSHTunnel: @unchecked Sendable {
    public let ssh: SSHConfig
    public let remoteHost: String
    public let remotePort: Int
    /// Kept across restarts so a database driver can reconnect to the same address.
    public private(set) var localPort: Int = 0
    private let secrets: ConnectionSecrets
    private let knownHosts: SSHKnownHosts
    private var forwarder: SSHForwarder?
    private let lock = NSLock()

    public init(ssh: SSHConfig, secrets: ConnectionSecrets = ConnectionSecrets(), remoteHost: String, remotePort: Int,
                knownHosts: SSHKnownHosts = .shared) {
        self.ssh = ssh
        self.secrets = secrets
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.knownHosts = knownHosts
    }

    deinit { stop() }

    /// False once the SSH connection dropped; `start()` opens it again on the same local port.
    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return forwarder?.isRunning ?? false
    }

    /// The SSH host, port and sign-in options after applying ~/.ssh/config.
    public static func endpoint(for ssh: SSHConfig, secrets: ConnectionSecrets,
                                settings: SSHHostSettings? = nil) throws -> (host: String, port: Int, credentials: SSHCredentials) {
        let alias = ssh.host.trimmingCharacters(in: .whitespaces)
        guard !alias.isEmpty else { throw DatabaseError("SSH: enter the SSH host") }
        let file = settings ?? SSHConfigFile.settings(for: alias)
        if let proxy = file.proxy {
            throw DatabaseError("SSH: \(alias) uses ProxyJump/ProxyCommand (\(proxy)) in ~/.ssh/config, which TableExtra does not support yet. Connect to the last hop directly.")
        }
        let user = ssh.user.isEmpty ? (file.user ?? NSUserName()) : ssh.user
        let port = ssh.port == 22 ? (file.port ?? 22) : ssh.port
        var credentials = SSHCredentials(user: user,
                                         privateKeyPath: ssh.privateKeyPath.isEmpty ? nil : ssh.privateKeyPath,
                                         passphrase: secrets.sshKeyPassphrase,
                                         password: secrets.sshPassword)
        credentials.configIdentityFiles = file.identityFiles
        credentials.identityAgent = file.identityAgent
        return (file.hostName ?? alias, port, credentials)
    }

    public func start(timeout: TimeInterval = 15) throws {
        stop()
        let endpoint = try Self.endpoint(for: ssh, secrets: secrets)
        let listener = try SSHForwarder.listen(port: localPort)
        let session: SSHSession
        do {
            session = try SSHSession(host: endpoint.host, port: endpoint.port, timeout: timeout)
            do {
                try session.verifyHostKey(store: knownHosts)
                try session.authenticate(endpoint.credentials)
            } catch {
                session.close()
                throw error
            }
        } catch {
            Darwin.close(listener.fd)
            throw error
        }
        localPort = listener.port
        let f = try SSHForwarder(session: session, listener: listener.fd, localPort: listener.port, remoteHost: remoteHost, remotePort: remotePort)
        lock.lock()
        forwarder = f
        lock.unlock()
        f.start()
    }

    public func stop() {
        lock.lock()
        let f = forwarder
        forwarder = nil
        lock.unlock()
        f?.stop()
    }
}

/// Relays local connections through `direct-tcpip` channels. Owns the session: every libssh2 call after `start()`
/// happens on its thread, which polls the SSH socket, the listener and the accepted sockets.
final class SSHForwarder: @unchecked Sendable {
    private final class Link {
        let fd: Int32
        var channel: OpaquePointer?
        /// Read from the local socket, not yet accepted by the channel.
        var outbound: [UInt8] = []
        var localEOF = false
        var eofSent = false
        var done = false

        init(fd: Int32) { self.fd = fd }
    }

    private let session: SSHSession
    private let listener: Int32
    private let localPort: Int
    private let remoteHost: String
    private let remotePort: Int
    private var links: [Link] = []
    private var closing: [(channel: OpaquePointer, closed: Bool)] = []
    private var wakeRead: Int32 = -1
    private var wakeWrite: Int32 = -1
    private let finished = DispatchSemaphore(value: 0)
    private let stateLock = NSLock()
    private var running = true
    private var stopRequested = false
    private static let bufferSize = 64 * 1024

    init(session: SSHSession, listener: Int32, localPort: Int, remoteHost: String, remotePort: Int) throws {
        self.session = session
        self.listener = listener
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        var pipeFDs: [Int32] = [-1, -1]
        guard pipe(&pipeFDs) == 0 else {
            session.close()
            Darwin.close(listener)
            throw DatabaseError("SSH: cannot create the tunnel's wake-up pipe")
        }
        wakeRead = pipeFDs[0]
        wakeWrite = pipeFDs[1]
    }

    deinit {
        Darwin.close(wakeRead)
        Darwin.close(wakeWrite)
    }

    var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return running
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "TableExtra SSH tunnel :\(localPort)"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func stop() {
        stateLock.lock()
        let wasRunning = running
        stopRequested = true
        stateLock.unlock()
        guard wasRunning else { return }
        var byte: UInt8 = 1
        _ = write(wakeWrite, &byte, 1)
        _ = finished.wait(timeout: .now() + 3)
    }

    private var shouldStop: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return stopRequested
    }

    /// Binds 127.0.0.1:`port` (0 = any free port) and returns the socket and the port it got.
    static func listen(port: Int) throws -> (fd: Int32, port: Int) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DatabaseError("SSH: cannot open a local port") }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        func bindTo(_ p: Int) -> Bool {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            addr.sin_port = UInt16(p).bigEndian
            return withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
            }
        }
        guard (port != 0 && bindTo(port)) || bindTo(0), Darwin.listen(fd, 32) == 0 else {
            Darwin.close(fd)
            throw DatabaseError("SSH: cannot listen on a local port")
        }
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        return (fd, Int(UInt16(bigEndian: addr.sin_port)))
    }

    // MARK: Loop

    private func run() {
        let raw = session.raw
        libssh2_session_set_blocking(raw, 0)
        libssh2_keepalive_config(raw, 1, 30)
        var buffer = [UInt8](repeating: 0, count: Self.bufferSize)
        var sessionAlive = true

        while sessionAlive && !shouldStop {
            var fds = [pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: listener, events: Int16(POLLIN), revents: 0)]
            var sshEvents = Int16(POLLIN)
            if libssh2_session_block_directions(raw) & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0 || links.contains(where: { !$0.outbound.isEmpty }) {
                sshEvents |= Int16(POLLOUT)
            }
            fds.append(pollfd(fd: session.socket, events: sshEvents, revents: 0))
            let firstLink = fds.count
            let polled = links
            for link in polled {
                let wantsRead = link.channel != nil && !link.localEOF && link.outbound.count < Self.bufferSize
                fds.append(pollfd(fd: link.fd, events: wantsRead ? Int16(POLLIN) : 0, revents: 0))
            }
            let buffered = links.contains { $0.channel.map { libssh2_poll_channel_read($0, 0) != 0 } ?? false }
            let timeout: Int32 = buffered ? 0 : (links.isEmpty && closing.isEmpty ? 1000 : 100)
            if poll(&fds, nfds_t(fds.count), timeout) < 0 && errno != EINTR { break }
            if fds[0].revents != 0 { break }
            if fds[1].revents & Int16(POLLIN) != 0 { acceptClients() }

            for (i, link) in polled.enumerated() where fds[firstLink + i].revents != 0 {
                let n = recv(link.fd, &buffer, buffer.count, 0)
                if n > 0 {
                    link.outbound.append(contentsOf: buffer[0..<n])
                } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
                    link.localEOF = true
                }
            }
            for link in links where !link.done {
                if !pump(link, buffer: &buffer) { sessionAlive = false; break }
            }
            for link in links where link.done { closeLink(link) }
            links.removeAll { $0.done }
            drainClosing()

            var nextKeepalive: Int32 = 0
            let rc = libssh2_keepalive_send(raw, &nextKeepalive)
            if rc != 0 && rc != LIBSSH2_ERROR_EAGAIN { sessionAlive = false }
        }
        shutdown()
    }

    private func acceptClients() {
        while true {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
            SSHSocket.configure(fd)
            links.append(Link(fd: fd))
        }
    }

    /// Moves data both ways for one link. Returns false when the SSH session itself failed.
    private func pump(_ link: Link, buffer: inout [UInt8]) -> Bool {
        let raw = session.raw
        if link.channel == nil {
            guard let channel = libssh2_channel_direct_tcpip_ex(raw, remoteHost, Int32(remotePort), "127.0.0.1", Int32(localPort)) else {
                let code = session.lastErrno
                if code == LIBSSH2_ERROR_EAGAIN { return true }
                link.done = true
                return !Self.isSessionFailure(code)
            }
            link.channel = channel
        }
        guard let channel = link.channel else { return true }

        while !link.outbound.isEmpty {
            let written = link.outbound.withUnsafeBytes { bytes in
                libssh2_channel_write_ex(channel, 0, bytes.baseAddress?.assumingMemoryBound(to: CChar.self), bytes.count)
            }
            if written > 0 {
                link.outbound.removeFirst(written)
            } else if written == Int(LIBSSH2_ERROR_EAGAIN) {
                break
            } else {
                link.done = true
                return !Self.isSessionFailure(Int32(written))
            }
        }
        if link.localEOF && link.outbound.isEmpty && !link.eofSent {
            let rc = libssh2_channel_send_eof(channel)
            if rc == 0 { link.eofSent = true; link.done = true } else if rc != LIBSSH2_ERROR_EAGAIN { link.done = true }
        }

        while true {
            let read = buffer.withUnsafeMutableBytes { bytes in
                libssh2_channel_read_ex(channel, 0, bytes.baseAddress?.assumingMemoryBound(to: CChar.self), bytes.count)
            }
            if read > 0 {
                if !sendAll(link.fd, buffer, count: read) { link.done = true; return true }
            } else if read == Int(LIBSSH2_ERROR_EAGAIN) || read == 0 {
                break
            } else {
                link.done = true
                return !Self.isSessionFailure(Int32(read))
            }
        }
        if libssh2_channel_eof(channel) != 0 { link.done = true }
        return true
    }

    private func sendAll(_ fd: Int32, _ buffer: [UInt8], count: Int) -> Bool {
        var offset = 0
        while offset < count {
            let n = buffer.withUnsafeBytes { send(fd, $0.baseAddress! + offset, count - offset, 0) }
            if n > 0 { offset += n } else if n < 0 && errno == EINTR { continue } else { return false }
        }
        return true
    }

    private func closeLink(_ link: Link) {
        Darwin.close(link.fd)
        if let channel = link.channel { closing.append((channel, false)) }
        link.channel = nil
    }

    private func drainClosing() {
        closing = closing.compactMap { entry in
            var entry = entry
            if !entry.closed {
                let rc = libssh2_channel_close(entry.channel)
                if rc == LIBSSH2_ERROR_EAGAIN { return entry }
                entry.closed = true
            }
            return libssh2_channel_free(entry.channel) == LIBSSH2_ERROR_EAGAIN ? entry : nil
        }
    }

    private static func isSessionFailure(_ code: Int32) -> Bool {
        [LIBSSH2_ERROR_SOCKET_DISCONNECT, LIBSSH2_ERROR_SOCKET_SEND, LIBSSH2_ERROR_SOCKET_RECV,
         LIBSSH2_ERROR_SOCKET_TIMEOUT, LIBSSH2_ERROR_TIMEOUT, LIBSSH2_ERROR_KEX_FAILURE].contains(code)
    }

    private func shutdown() {
        for link in links { closeLink(link) }
        links.removeAll()
        libssh2_session_set_blocking(session.raw, 1)
        libssh2_session_set_timeout(session.raw, 1000)
        for entry in closing {
            if !entry.closed { libssh2_channel_close(entry.channel) }
            libssh2_channel_free(entry.channel)
        }
        closing.removeAll()
        session.close()
        Darwin.close(listener)
        stateLock.lock()
        running = false
        stateLock.unlock()
        finished.signal()
    }
}
