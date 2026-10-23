import Foundation

public enum AppPaths {
    /// ~/Library/Application Support/TableExtra (override with TABLEEXTRA_HOME, or the legacy MYTABLEPLUS_HOME, for tests).
    public static var root: URL {
        let env = ProcessInfo.processInfo.environment
        if let custom = env["TABLEEXTRA_HOME"] ?? env["MYTABLEPLUS_HOME"], !custom.isEmpty {
            return ensure(URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true))
        }
        return defaultRoot
    }

    /// The app was called MyTablePlus before; its data folder is moved over on first use.
    static let legacyFolderName = "MyTablePlus"

    private static let defaultRoot: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("TableExtra", isDirectory: true)
        let legacy = base.appendingPathComponent(legacyFolderName, isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path), fm.fileExists(atPath: legacy.path) {
            try? fm.moveItem(at: legacy, to: url)
        }
        return ensure(url)
    }()

    public static var connectionsFile: URL { root.appendingPathComponent("connections.json") }
    public static var favoritesFile: URL { root.appendingPathComponent("favorites.json") }
    public static var historyDatabase: URL { root.appendingPathComponent("history.sqlite") }
    public static var workspaceStateFile: URL { root.appendingPathComponent("workspaces.json") }
    public static var themesDirectory: URL { ensure(root.appendingPathComponent("Themes", isDirectory: true)) }
    public static var backupsDirectory: URL { ensure(root.appendingPathComponent("Backups", isDirectory: true)) }
    public static var diagramsDirectory: URL { ensure(root.appendingPathComponent("Diagrams", isDirectory: true)) }
    public static var mcpAuditLog: URL { root.appendingPathComponent("mcp-audit.log") }

    public static var tablePlusData: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.tinyapp.TablePlus/Data", isDirectory: true)
    }

    @discardableResult
    static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
