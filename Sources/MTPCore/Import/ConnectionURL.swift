import Foundation

/// postgres://user:pass@host:5432/db?sslmode=require  ·  sqlite:///path/to/file.db
public enum ConnectionURL {
    public static func parse(_ raw: String) -> (ConnectionConfig, ConnectionSecrets)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            var c = ConnectionConfig(name: (trimmed as NSString).lastPathComponent, driver: .sqlite)
            c.filePath = trimmed
            return (c, ConnectionSecrets())
        }
        guard let comps = URLComponents(string: trimmed), let scheme = comps.scheme?.lowercased() else { return nil }
        let base = scheme.replacingOccurrences(of: "+ssh", with: "")
        guard let driver = DriverKind.allCases.first(where: { $0.urlSchemes.contains(base) }) else { return nil }

        var c = ConnectionConfig(driver: driver)
        if driver == .sqlite {
            c.filePath = comps.path.removingPercentEncoding ?? comps.path
            c.name = (c.filePath as NSString).lastPathComponent
            return (c, ConnectionSecrets())
        }
        c.host = comps.host ?? "127.0.0.1"
        c.port = comps.port
        c.user = comps.user?.removingPercentEncoding ?? ""
        let path = comps.path.hasPrefix("/") ? String(comps.path.dropFirst()) : comps.path
        c.database = path.removingPercentEncoding ?? path
        for item in comps.queryItems ?? [] {
            guard let v = item.value else { continue }
            switch item.name {
            case "sslmode": c.sslMode = SSLMode(rawValue: v) ?? c.sslMode
            case "name", "statusColor", "env", "enviroment", "environment":
                if item.name == "name" { c.name = v }
                if ["env", "enviroment", "environment"].contains(item.name) { c.environment = ConnectionEnvironment(rawValue: v.lowercased()) ?? c.environment }
            default:
                c.extraOptions[item.name] = v
            }
        }
        if c.name.isEmpty { c.name = c.database.isEmpty ? c.host : "\(c.database) @ \(c.host)" }
        if c.host.contains("rds.amazonaws.com") || c.host.contains("supabase") || c.host.contains("neon.tech") {
            if c.sslMode == .prefer { c.sslMode = .require }
        }
        c.safety = c.environment.defaultSafety
        return (c, ConnectionSecrets(password: comps.password?.removingPercentEncoding))
    }

    public static func make(_ c: ConnectionConfig, password: String?, includePassword: Bool = false) -> String {
        switch c.driver {
        case .sqlite:
            return "sqlite://" + c.filePath
        case .postgres:
            var comps = URLComponents()
            comps.scheme = "postgresql"
            comps.host = c.host
            comps.port = c.port
            comps.user = c.user.isEmpty ? nil : c.user
            if includePassword { comps.password = password }
            comps.path = "/" + c.database
            var items = [URLQueryItem]()
            if c.sslMode != .prefer { items.append(URLQueryItem(name: "sslmode", value: c.sslMode.rawValue)) }
            comps.queryItems = items.isEmpty ? nil : items
            return comps.string ?? ""
        }
    }
}
