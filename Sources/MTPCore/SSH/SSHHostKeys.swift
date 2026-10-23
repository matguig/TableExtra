import CryptoKit
import Foundation

/// A server's public host key, as sent during the SSH handshake.
public struct SSHHostKey: Equatable, Sendable {
    /// Raw key blob (`string type, …` in SSH wire format).
    public var blob: Data

    public init(blob: Data) {
        self.blob = blob
    }

    /// Key type from the blob, e.g. `ssh-ed25519`, `ecdsa-sha2-nistp256`, `ssh-rsa`.
    public var type: String {
        guard blob.count >= 4 else { return "unknown" }
        let length = blob.prefix(4).reduce(0) { $0 << 8 | Int($1) }
        guard length > 0, blob.count >= 4 + length else { return "unknown" }
        return String(decoding: blob.dropFirst(4).prefix(length), as: UTF8.self)
    }

    /// OpenSSH-style fingerprint: `SHA256:` + unpadded base64 of the blob's SHA-256.
    public var fingerprint: String {
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
}

/// Host keys TableExtra has accepted (trust on first use, like `StrictHostKeyChecking=accept-new`).
/// Stored in `known_hosts.json` next to the connections; ~/.ssh/known_hosts is checked first when readable.
public final class SSHKnownHosts: @unchecked Sendable {
    public static let shared = SSHKnownHosts(file: AppPaths.root.appendingPathComponent("known_hosts.json"))

    public struct Entry: Codable, Equatable, Sendable {
        public var type: String
        public var key: String
        public var fingerprint: String
        public var addedAt: Date
    }

    private let file: URL
    private let lock = NSLock()

    public init(file: URL) {
        self.file = file
    }

    /// `host` for port 22, `[host]:port` otherwise (the known_hosts convention).
    public static func label(host: String, port: Int) -> String {
        port == 22 ? host.lowercased() : "[\(host.lowercased())]:\(port)"
    }

    public func entry(host: String, port: Int) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return load()[Self.label(host: host, port: port)]
    }

    public func trust(_ key: SSHHostKey, host: String, port: Int) {
        lock.lock(); defer { lock.unlock() }
        var all = load()
        all[Self.label(host: host, port: port)] = Entry(type: key.type, key: key.blob.base64EncodedString(), fingerprint: key.fingerprint, addedAt: Date())
        save(all)
    }

    /// Removes the saved key so the next connection accepts the server's current one.
    @discardableResult
    public func forget(host: String, port: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var all = load()
        guard all.removeValue(forKey: Self.label(host: host, port: port)) != nil else { return false }
        save(all)
        return true
    }

    private func load() -> [String: Entry] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: Entry].self, from: data)) ?? [:]
    }

    private func save(_ all: [String: Entry]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(all) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
