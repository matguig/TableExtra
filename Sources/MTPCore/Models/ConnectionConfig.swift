import Foundation

public enum DriverKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case postgres
    case sqlite

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .postgres: return "PostgreSQL"
        case .sqlite: return "SQLite"
        }
    }

    public var shortName: String {
        switch self {
        case .postgres: return "Pg"
        case .sqlite: return "SL"
        }
    }

    public var defaultPort: Int? {
        switch self {
        case .postgres: return 5432
        case .sqlite: return nil
        }
    }

    public var urlSchemes: [String] {
        switch self {
        case .postgres: return ["postgres", "postgresql"]
        case .sqlite: return ["sqlite", "file"]
        }
    }
}

/// Where a connection lives. Drives the window tint and the default safety level.
public enum ConnectionEnvironment: String, Codable, CaseIterable, Sendable, Identifiable {
    case local
    case development
    case testing
    case staging
    case production

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .local: return "Local"
        case .development: return "Development"
        case .testing: return "Testing"
        case .staging: return "Staging"
        case .production: return "Production"
        }
    }

    /// Default tag colors, same palette family as TablePlus status colors.
    public var defaultColorHex: String {
        switch self {
        case .local: return "#8E8E93"
        case .development: return "#34C759"
        case .testing: return "#5AC8FA"
        case .staging: return "#FF9F0A"
        case .production: return "#FF3B30"
        }
    }

    public var defaultSafety: SafetyLevel {
        switch self {
        case .local, .development, .testing: return .silent
        case .staging: return .confirmWrites
        case .production: return .confirmWrites
        }
    }
}

/// Query safety, a superset of TablePlus Silent / Warning / Safe modes.
public enum SafetyLevel: Int, Codable, CaseIterable, Sendable, Identifiable {
    /// Send queries without any warning.
    case silent = 0
    /// Ask for confirmation before any statement that writes.
    case confirmWrites = 1
    /// Require Touch ID / password before any statement that writes.
    case protectedWrites = 2
    /// Never send writes; the session is opened read-only.
    case readOnly = 3

    public var id: Int { rawValue }

    public var displayName: String {
        switch self {
        case .silent: return "Silent — no warning"
        case .confirmWrites: return "Warning — confirm every write"
        case .protectedWrites: return "Safe — Touch ID before every write"
        case .readOnly: return "Read-only — writes are blocked"
        }
    }
}

public enum SSLMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case disable, allow, prefer, require
    case verifyCA = "verify-ca"
    case verifyFull = "verify-full"

    public var id: String { rawValue }
}

/// Which MCP clients (Claude Code…) may use this connection through `tableextra-mcp`.
public enum MCPAccess: String, Codable, CaseIterable, Sendable, Identifiable {
    case none
    case readOnly
    case readWrite

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: return "Hidden from agents"
        case .readOnly: return "Read-only for agents"
        case .readWrite: return "Read & write for agents"
        }
    }
}

public struct SSHConfig: Codable, Hashable, Sendable {
    public var enabled: Bool = false
    public var host: String = ""
    public var port: Int = 22
    public var user: String = ""
    /// Path to a private key; empty means ~/.ssh/config IdentityFile, ssh-agent, then ~/.ssh/id_* keys.
    public var privateKeyPath: String = ""

    public init() {}
}

public struct ConnectionConfig: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var driver: DriverKind
    public var host: String
    public var port: Int?
    public var user: String
    public var database: String
    public var sslMode: SSLMode
    /// SQLite database file.
    public var filePath: String
    public var environment: ConnectionEnvironment
    public var colorHex: String?
    public var groupID: UUID?
    public var safety: SafetyLevel
    /// Run writes in a rolled-back transaction first to report the affected row count.
    public var dryRunWrites: Bool
    /// Refuse UPDATE / DELETE without WHERE unless explicitly confirmed.
    public var guardUnboundedWrites: Bool
    public var ssh: SSHConfig
    public var startupSQL: String
    /// Extra libpq keywords (application_name, connect_timeout, options…).
    public var extraOptions: [String: String]
    public var mcpAccess: MCPAccess
    /// Folder of the application code that uses this database; Claude may read it (read-only) for context.
    public var codeRepository: String?
    /// Whether the in-app Claude assistant may run read-only queries and see rows. nil = environment default.
    public var claudeCanQuery: Bool?
    /// AWS RDS monitoring (read-only, through the `aws` CLI and the user's profiles). nil = not configured.
    public var aws: AWSSettings?
    public var defaultSchema: String?
    public var pageSize: Int?
    public var tablePlusID: String?
    public var lastConnectedAt: Date?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String = "",
        driver: DriverKind = .postgres,
        host: String = "127.0.0.1",
        port: Int? = nil,
        user: String = "",
        database: String = "",
        sslMode: SSLMode = .prefer,
        filePath: String = "",
        environment: ConnectionEnvironment = .local,
        colorHex: String? = nil,
        groupID: UUID? = nil,
        safety: SafetyLevel? = nil,
        dryRunWrites: Bool? = nil,
        guardUnboundedWrites: Bool = true,
        ssh: SSHConfig = SSHConfig(),
        startupSQL: String = "",
        extraOptions: [String: String] = [:],
        mcpAccess: MCPAccess? = nil,
        defaultSchema: String? = nil,
        pageSize: Int? = nil,
        tablePlusID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.driver = driver
        self.host = host
        self.port = port
        self.user = user
        self.database = database
        self.sslMode = sslMode
        self.filePath = filePath
        self.environment = environment
        self.colorHex = colorHex
        self.groupID = groupID
        self.safety = safety ?? environment.defaultSafety
        self.dryRunWrites = dryRunWrites ?? (environment == .production || environment == .staging)
        self.guardUnboundedWrites = guardUnboundedWrites
        self.ssh = ssh
        self.startupSQL = startupSQL
        self.extraOptions = extraOptions
        self.mcpAccess = mcpAccess ?? (environment == .production ? .readOnly : .readWrite)
        self.defaultSchema = defaultSchema
        self.pageSize = pageSize
        self.tablePlusID = tablePlusID
        self.lastConnectedAt = nil
        self.createdAt = Date()
    }

    public var effectiveColorHex: String { colorHex ?? environment.defaultColorHex }

    public var effectivePort: Int { port ?? driver.defaultPort ?? 0 }

    /// RDS endpoint recognised from the host, if any (instance, Aurora cluster or proxy).
    public var rdsEndpoint: RDSEndpoint? { RDSEndpoint.parse(host) }

    /// AWS settings to use: the saved ones, else what the host implies (identifier + region, default profile).
    public var effectiveAWS: AWSSettings? {
        if let aws, aws.isEnabled { return aws.filled(from: rdsEndpoint) }
        if aws?.isEnabled == false { return nil }
        guard let ep = rdsEndpoint else { return nil }
        return AWSSettings(profile: nil, region: ep.region, identifier: ep.identifier, isCluster: ep.kind == .cluster)
    }

    /// Claude may query this connection (read-only) and read rows: on by default for local/dev/test, off for staging/production.
    public var effectiveClaudeCanQuery: Bool { claudeCanQuery ?? !isProductionLike }

    /// Existing directory for `codeRepository`, if any.
    public var codeRepositoryURL: URL? {
        guard let p = codeRepository?.trimmingCharacters(in: .whitespaces), !p.isEmpty else { return nil }
        let path = (p as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue ? URL(fileURLWithPath: path, isDirectory: true) : nil
    }

    public var isProductionLike: Bool { environment == .production || environment == .staging }

    /// "postgres : 127.0.0.1 : shop" style summary used across the UI.
    public var subtitle: String {
        switch driver {
        case .sqlite:
            return (filePath as NSString).abbreviatingWithTildeInPath
        case .postgres:
            let db = database.isEmpty ? user : database
            return "\(user.isEmpty ? "" : user + "@")\(host):\(effectivePort)/\(db)"
        }
    }

    // Tolerate files written by older builds that lack newer keys.
    enum CodingKeys: String, CodingKey {
        case id, name, driver, host, port, user, database, sslMode, filePath, environment, colorHex, groupID
        case safety, dryRunWrites, guardUnboundedWrites, ssh, startupSQL, extraOptions, mcpAccess, codeRepository, claudeCanQuery, aws
        case defaultSchema, pageSize, tablePlusID, lastConnectedAt, createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        driver = try c.decodeIfPresent(DriverKind.self, forKey: .driver) ?? .postgres
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? ""
        database = try c.decodeIfPresent(String.self, forKey: .database) ?? ""
        sslMode = try c.decodeIfPresent(SSLMode.self, forKey: .sslMode) ?? .prefer
        filePath = try c.decodeIfPresent(String.self, forKey: .filePath) ?? ""
        environment = try c.decodeIfPresent(ConnectionEnvironment.self, forKey: .environment) ?? .local
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex)
        groupID = try c.decodeIfPresent(UUID.self, forKey: .groupID)
        safety = try c.decodeIfPresent(SafetyLevel.self, forKey: .safety) ?? environment.defaultSafety
        dryRunWrites = try c.decodeIfPresent(Bool.self, forKey: .dryRunWrites) ?? false
        guardUnboundedWrites = try c.decodeIfPresent(Bool.self, forKey: .guardUnboundedWrites) ?? true
        ssh = try c.decodeIfPresent(SSHConfig.self, forKey: .ssh) ?? SSHConfig()
        startupSQL = try c.decodeIfPresent(String.self, forKey: .startupSQL) ?? ""
        extraOptions = try c.decodeIfPresent([String: String].self, forKey: .extraOptions) ?? [:]
        mcpAccess = try c.decodeIfPresent(MCPAccess.self, forKey: .mcpAccess) ?? .readOnly
        codeRepository = try c.decodeIfPresent(String.self, forKey: .codeRepository)
        claudeCanQuery = try c.decodeIfPresent(Bool.self, forKey: .claudeCanQuery)
        aws = try c.decodeIfPresent(AWSSettings.self, forKey: .aws)
        defaultSchema = try c.decodeIfPresent(String.self, forKey: .defaultSchema)
        pageSize = try c.decodeIfPresent(Int.self, forKey: .pageSize)
        tablePlusID = try c.decodeIfPresent(String.self, forKey: .tablePlusID)
        lastConnectedAt = try c.decodeIfPresent(Date.self, forKey: .lastConnectedAt)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

public struct ConnectionGroup: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var colorHex: String?
    public var tablePlusID: String?

    public init(id: UUID = UUID(), name: String, colorHex: String? = nil, tablePlusID: String? = nil) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.tablePlusID = tablePlusID
    }
}

/// Secrets live in the Keychain, never in connections.json.
public struct ConnectionSecrets: Sendable {
    public var password: String?
    public var sshPassword: String?
    /// Passphrase of `SSHConfig.privateKeyPath`, when the key is encrypted.
    public var sshKeyPassphrase: String?

    public init(password: String? = nil, sshPassword: String? = nil, sshKeyPassphrase: String? = nil) {
        self.password = password
        self.sshPassword = sshPassword
        self.sshKeyPassphrase = sshKeyPassphrase
    }
}

/// How TableExtra reads RDS / CloudWatch / Performance Insights for a connection.
public struct AWSSettings: Codable, Hashable, Sendable {
    /// `aws --profile`; nil = the CLI's default resolution (AWS_PROFILE, then "default").
    public var profile: String?
    public var region: String?
    /// DB instance identifier, or cluster identifier when `isCluster`.
    public var identifier: String?
    public var isCluster: Bool
    /// False hides RDS for this connection even when the host is an RDS endpoint.
    public var isEnabled: Bool

    public init(profile: String? = nil, region: String? = nil, identifier: String? = nil, isCluster: Bool = false, isEnabled: Bool = true) {
        self.profile = profile
        self.region = region
        self.identifier = identifier
        self.isCluster = isCluster
        self.isEnabled = isEnabled
    }

    /// Missing region / identifier taken from the endpoint.
    public func filled(from ep: RDSEndpoint?) -> AWSSettings {
        var s = self
        if s.region?.isEmpty ?? true { s.region = ep?.region }
        if s.identifier?.isEmpty ?? true {
            s.identifier = ep?.identifier
            s.isCluster = ep?.kind == .cluster
        }
        return s
    }

    public var isComplete: Bool { !(region ?? "").isEmpty && !(identifier ?? "").isEmpty }
}

/// What an RDS hostname tells us: `<id>.<hash>.<region>.rds.amazonaws.com`, `<id>.cluster-<hash>…` (Aurora writer),
/// `<id>.cluster-ro-<hash>…` (Aurora readers), `<id>.proxy-<hash>…` (RDS Proxy).
public struct RDSEndpoint: Hashable, Sendable {
    public enum Kind: String, Sendable { case instance, cluster, proxy }
    public var identifier: String
    public var region: String
    public var kind: Kind

    public static func parse(_ host: String) -> RDSEndpoint? {
        let h = host.lowercased().trimmingCharacters(in: .whitespaces)
        let suffix = h.hasSuffix(".rds.amazonaws.com") ? ".rds.amazonaws.com" : (h.hasSuffix(".rds.amazonaws.com.cn") ? ".rds.amazonaws.com.cn" : nil)
        guard let suffix else { return nil }
        let labels = h.dropLast(suffix.count).split(separator: ".").map(String.init)
        // <id>.<hash>.<region>
        guard labels.count == 3 else { return nil }
        let region = labels[2]
        guard region.range(of: #"^[a-z]{2}(-gov)?-[a-z]+-\d$"#, options: .regularExpression) != nil else { return nil }
        let hash = labels[1]
        let kind: Kind = hash.hasPrefix("cluster-") ? .cluster : (hash.hasPrefix("proxy-") ? .proxy : .instance)
        return RDSEndpoint(identifier: labels[0], region: region, kind: kind)
    }
}

