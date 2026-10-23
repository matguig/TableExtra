import Foundation

/// Settings from ~/.ssh/config that apply to one host. TableExtra uses HostName, User, Port, IdentityFile and
/// IdentityAgent; ProxyJump / ProxyCommand are reported because the built-in client cannot follow them.
public struct SSHHostSettings: Equatable, Sendable {
    public var hostName: String?
    public var user: String?
    public var port: Int?
    public var identityFiles: [String] = []
    public var identityAgent: String?
    public var proxy: String?

    public init() {}
}

public enum SSHConfigFile {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
    }

    /// Settings for `host` from the user's ~/.ssh/config (empty when the file is missing or unreadable).
    public static func settings(for host: String) -> SSHHostSettings {
        guard let text = try? String(contentsOf: defaultURL, encoding: .utf8) else { return SSHHostSettings() }
        return settings(for: host, in: text)
    }

    /// Like ssh(1), the first value found for a keyword wins; IdentityFile accumulates.
    /// `Match` blocks and `Include` are not supported and are skipped.
    public static func settings(for host: String, in text: String, home: String = NSHomeDirectory()) -> SSHHostSettings {
        var result = SSHHostSettings()
        var applies = true
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let (keyword, value) = split(line) else { continue }
            switch keyword {
            case "host":
                applies = matches(host: host, patterns: value)
                continue
            case "match":
                applies = false
                continue
            default:
                break
            }
            guard applies else { continue }
            switch keyword {
            case "hostname" where result.hostName == nil:
                result.hostName = value.replacingOccurrences(of: "%h", with: host).replacingOccurrences(of: "%%", with: "%")
            case "user" where result.user == nil:
                result.user = value
            case "port" where result.port == nil:
                result.port = Int(value)
            case "identityfile":
                result.identityFiles.append(expand(value, host: host, home: home))
            case "identityagent" where result.identityAgent == nil:
                result.identityAgent = value == "SSH_AUTH_SOCK" || value == "none" ? value : expand(value, host: host, home: home)
            case "proxyjump" where result.proxy == nil, "proxycommand" where result.proxy == nil:
                if value.lowercased() != "none" { result.proxy = value }
            default:
                break
            }
        }
        return result
    }

    /// `Keyword value`, `Keyword=value` or `Keyword "quoted value"`.
    static func split(_ line: String) -> (String, String)? {
        guard let sep = line.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) else { return nil }
        let keyword = line[..<sep].lowercased()
        var value = line[sep...].drop(while: { $0 == " " || $0 == "\t" || $0 == "=" }).trimmingCharacters(in: .whitespaces)
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
        return value.isEmpty ? nil : (keyword, value)
    }

    /// `Host` pattern list: any positive glob match, and no negated (`!pattern`) match.
    static func matches(host: String, patterns: String) -> Bool {
        var matched = false
        for pattern in patterns.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            if pattern.hasPrefix("!") {
                if fnmatch(String(pattern.dropFirst()).lowercased(), host.lowercased(), 0) == 0 { return false }
            } else if fnmatch(pattern.lowercased(), host.lowercased(), 0) == 0 {
                matched = true
            }
        }
        return matched
    }

    static func expand(_ path: String, host: String, home: String) -> String {
        var p = path.replacingOccurrences(of: "%d", with: home).replacingOccurrences(of: "%h", with: host)
            .replacingOccurrences(of: "%u", with: NSUserName()).replacingOccurrences(of: "%%", with: "%")
        if p.hasPrefix("~/") { p = home + p.dropFirst() } else if p == "~" { p = home }
        return p
    }
}
