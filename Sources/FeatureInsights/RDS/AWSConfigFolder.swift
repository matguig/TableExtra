import AppKit
import Foundation
import MTPCore

/// The user's AWS configuration folder (usually ~/.aws). TableExtra reads it only after the user picks it in an open
/// panel; the choice is kept as a security-scoped bookmark (in the app's data folder) so it also works in a sandboxed
/// build. Nothing is written to the AWS folder.
public enum AWSConfigFolder {
    nonisolated(unsafe) static var bookmarkFile: URL = AppPaths.root.appendingPathComponent("aws-folder.bookmark")
    nonisolated(unsafe) private static var opened: URL?
    private static let lock = NSLock()

    /// The real ~/.aws, also inside a sandbox (where NSHomeDirectory() is the app container).
    public static var suggestedURL: URL {
        let home = getpwuid(getuid()).flatMap { $0.pointee.pw_dir.map { String(cString: $0) } } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".aws", isDirectory: true)
    }

    public static var isGranted: Bool { FileManager.default.fileExists(atPath: bookmarkFile.path) }

    /// Path of the granted folder, for display ("~/.aws").
    public static var displayPath: String? {
        guard let url = url() else { return nil }
        return (url.path as NSString).abbreviatingWithTildeInPath
    }

    /// Asks the user to pick the folder. Returns false when they cancel.
    @MainActor @discardableResult
    public static func requestAccess() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = suggestedURL.deletingLastPathComponent()
        panel.nameFieldStringValue = ".aws"
        panel.prompt = "Allow Access"
        panel.message = "Select your AWS folder (usually ~/.aws). TableExtra reads your profiles and credentials from it "
            + "to show RDS metrics, read-only. It never writes there."
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return grant(url)
    }

    @discardableResult
    public static func grant(_ url: URL) -> Bool {
        let data = (try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
        guard let data else { return false }
        lock.lock()
        opened?.stopAccessingSecurityScopedResource()
        opened = nil
        lock.unlock()
        try? FileManager.default.createDirectory(at: bookmarkFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: bookmarkFile, options: .atomic)) != nil
    }

    public static func revoke() {
        lock.lock()
        opened?.stopAccessingSecurityScopedResource()
        opened = nil
        lock.unlock()
        try? FileManager.default.removeItem(at: bookmarkFile)
    }

    /// The granted folder, opened for reading for the rest of the session (credentials can be re-read at any time:
    /// expiring role sessions, SSO token refresh). nil when access was never granted or the folder is gone.
    public static func url() -> URL? {
        lock.lock(); defer { lock.unlock() }
        if let opened { return opened }
        guard let data = try? Data(contentsOf: bookmarkFile) else { return nil }
        var stale = false
        let url = (try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale))
            ?? (try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale))
        guard let url else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            try? fresh.write(to: bookmarkFile, options: .atomic)
        }
        opened = url
        return url
    }

    public static var configFile: URL? { url()?.appendingPathComponent("config") }
    public static var credentialsFile: URL? { url()?.appendingPathComponent("credentials") }

    /// Profile names from `config` and `credentials`: only the [section] headers are read.
    public static func profileNames() -> [String] {
        guard let folder = url() else { return [] }
        var names = Set<String>()
        for (file, isConfig) in [("config", true), ("credentials", false)] {
            guard let text = try? String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8) else { continue }
            names.formUnion(profileNames(in: text, isConfig: isConfig))
        }
        return names.sorted()
    }

    /// In `config`, profiles are `[profile name]` (plus `[default]`); `[sso-session x]` and `[services x]` are not profiles.
    static func profileNames(in text: String, isConfig: Bool) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("["), t.hasSuffix("]") else { return nil }
            let name = String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            guard isConfig, name != "default" else { return name.isEmpty ? nil : name }
            guard name.hasPrefix("profile ") else { return nil }
            let profile = name.dropFirst("profile ".count).trimmingCharacters(in: .whitespaces)
            return profile.isEmpty ? nil : profile
        }
    }
}
