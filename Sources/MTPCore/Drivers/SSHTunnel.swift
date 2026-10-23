import Foundation

/// Local port forward through the system `ssh` binary, so ~/.ssh/config, ssh-agent and
/// ProxyJump work exactly as in Terminal. Password authentication is not supported.
public final class SSHTunnel: @unchecked Sendable {
    public let ssh: SSHConfig
    public let remoteHost: String
    public let remotePort: Int
    public private(set) var localPort: Int = 0
    private var process: Process?
    private let errorPipe = Pipe()

    public init(ssh: SSHConfig, remoteHost: String, remotePort: Int) {
        self.ssh = ssh
        self.remoteHost = remoteHost
        self.remotePort = remotePort
    }

    public func start(timeout: TimeInterval = 15) throws {
        localPort = try Self.freePort()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var args = ["-N", "-L", "127.0.0.1:\(localPort):\(remoteHost):\(remotePort)",
                    "-o", "ExitOnForwardFailure=yes", "-o", "BatchMode=yes", "-o", "ServerAliveInterval=30",
                    "-o", "StrictHostKeyChecking=accept-new", "-p", String(ssh.port)]
        if !ssh.privateKeyPath.isEmpty { args += ["-i", (ssh.privateKeyPath as NSString).expandingTildeInPath, "-o", "IdentitiesOnly=yes"] }
        args.append(ssh.user.isEmpty ? ssh.host : "\(ssh.user)@\(ssh.host)")
        p.arguments = args
        p.standardError = errorPipe
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        process = p

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !p.isRunning {
                let err = String(data: errorPipe.fileHandleForReading.availableData, encoding: .utf8) ?? ""
                throw DatabaseError("SSH tunnel failed: \(err.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            if Self.canConnect(port: localPort) { return }
            Thread.sleep(forTimeInterval: 0.15)
        }
        stop()
        throw DatabaseError("SSH tunnel to \(ssh.host) timed out")
    }

    public func stop() {
        if let process, process.isRunning { process.terminate() }
        process = nil
    }

    deinit { stop() }

    static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DatabaseError("Cannot allocate a local port") }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0 }
        }
        guard bound else { throw DatabaseError("Cannot allocate a local port") }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    static func canConnect(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = UInt16(port).bigEndian
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }
}
