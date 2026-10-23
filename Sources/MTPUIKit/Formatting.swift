import AppKit
import Foundation
import UniformTypeIdentifiers

public enum Fmt {
    public static func bytes(_ n: Int64?) -> String {
        guard let n else { return "—" }
        return ByteCountFormatter.string(fromByteCount: n, countStyle: .binary)
    }

    public static func count(_ n: Int64?) -> String {
        guard let n else { return "—" }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }

    /// 1.2K, 3.4M — compact row estimates in the sidebar.
    public static func compact(_ n: Int64?) -> String {
        guard let n else { return "" }
        switch n {
        case ..<1000: return String(n)
        case ..<1_000_000: return String(format: "%.1fK", Double(n) / 1000)
        case ..<1_000_000_000: return String(format: "%.1fM", Double(n) / 1_000_000)
        default: return String(format: "%.1fB", Double(n) / 1_000_000_000)
        }
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return String(format: "%.0f ms", seconds * 1000) }
        if seconds < 60 { return String(format: "%.2f s", seconds) }
        if seconds < 3600 { return String(format: "%dm %02ds", Int(seconds) / 60, Int(seconds) % 60) }
        return String(format: "%dh %02dm", Int(seconds) / 3600, (Int(seconds) % 3600) / 60)
    }

    public static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

public enum Pasteboard {
    public static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

@MainActor
public enum FilePanels {
    /// Shows a save panel and writes `contents`; returns the URL on success.
    @discardableResult
    public static func save(_ contents: String, suggestedName: String, types: [UTType] = [.plainText]) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = types
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            NSAlert(error: error).runModal()
            return nil
        }
    }

    public static func chooseSaveURL(suggestedName: String, types: [UTType]) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = types
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    public static func open(types: [UTType], allowsMultiple: Bool = false) -> [URL] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = allowsMultiple
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.urls : []
    }
}
