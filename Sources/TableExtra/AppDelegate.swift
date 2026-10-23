import AppKit
import FeatureDataTransfer
import MTPCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, MTPActions {
    private var welcome: WelcomeWindowController?
    private var settingsWindow: NSWindow?
    private var auxiliaryWindows: [NSWindow] = []
    private(set) var workspaces: [WorkspaceWindowController] = []

    static var shared: AppDelegate { NSApp.delegate as! AppDelegate }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.migrateLegacyDefaults()
        AppSettings.registerDefaults()
        AppSettings.applyAppearance()
        NSApp.mainMenu = MainMenu.build()
        NSWindow.allowsAutomaticWindowTabbing = true
        DebugAutomation.shared.start()
        if !restoreWorkspacesIfNeeded() { showWelcome(nil) }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The app was called MyTablePlus (bundle id fr.koa-dev.MyTablePlus); carry its settings over once.
    private static func migrateLegacyDefaults() {
        let defaults = UserDefaults.standard
        let flag = "migratedFromMyTablePlus"
        guard !defaults.bool(forKey: flag) else { return }
        if let old = defaults.persistentDomain(forName: "fr.koa-dev.MyTablePlus") {
            for (key, value) in old where defaults.object(forKey: key) == nil && !key.hasPrefix("NS") {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: flag)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWelcome(nil) }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let dirty = workspaces.filter { $0.model.hasUnsavedChanges }
        if !dirty.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Quit with uncommitted changes?"
            alert.informativeText = "\(dirty.map(\.model.connection.name).joined(separator: ", ")) still has pending data changes that were not committed."
            alert.addButton(withTitle: "Quit Anyway")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        WorkspaceSession.save(workspaces.map(\.model))
        return .terminateNow
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { open(url) }
    }

    // MARK: Windows

    @objc func showWelcome(_ sender: Any?) {
        if welcome == nil { welcome = WelcomeWindowController() }
        welcome?.showWindow(nil)
        welcome?.window?.makeKeyAndOrderFront(nil)
    }

    func closeWelcome() { welcome?.close() }

    @objc func newConnection(_ sender: Any?) {
        showWelcome(nil)
        welcome?.model.editing = ConnectionDraft.new()
    }

    @objc func importFromTablePlus(_ sender: Any?) {
        presentAuxiliary(title: "Import from TablePlus", size: NSSize(width: 720, height: 560)) { close in
            TablePlusImportView(onClose: close)
        }
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "Settings"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 760, height: 620))
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "sql")!, .init(filenameExtension: "sqlite")!, .init(filenameExtension: "db")!,
                                     .init(filenameExtension: "sqlite3")!, .database]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    @objc func openConnectionURL(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Open Connection URL"
        alert.informativeText = "postgresql://user:password@host:5432/database?sslmode=require"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        field.placeholderString = "postgresql://…"
        if let s = NSPasteboard.general.string(forType: .string), s.contains("://") { field.stringValue = s }
        alert.accessoryView = field
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, let url = URL(string: field.stringValue) else { return }
        open(url)
    }

    @objc func showHelp(_ sender: Any?) { openDoc("README.md") }
    @objc func showReverseEngineeringNotes(_ sender: Any?) { openDoc("docs/REVERSE_ENGINEERING.md") }

    @objc func setAppearance(_ sender: Any?) {
        guard let value = (sender as? NSMenuItem)?.representedObject as? String else { return }
        UserDefaults.standard.set(value, forKey: SettingKey.appearance)
        AppSettings.applyAppearance()
    }

    @objc func increaseFontSize(_ sender: Any?) { bumpFonts(1) }
    @objc func decreaseFontSize(_ sender: Any?) { bumpFonts(-1) }

    private func bumpFonts(_ delta: Double) {
        let d = UserDefaults.standard
        d.set(min(28, max(9, d.double(forKey: SettingKey.editorFontSize) + delta)), forKey: SettingKey.editorFontSize)
        d.set(min(24, max(9, d.double(forKey: SettingKey.gridFontSize) + delta)), forKey: SettingKey.gridFontSize)
        NotificationCenter.default.post(name: .mtpFontSizeChanged, object: nil)
    }

    private func openDoc(_ relative: String) {
        if let url = Bundle.main.resourceURL?.appendingPathComponent(relative), FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Small SwiftUI window for connection-level tools (import, backup, restore).
    func presentAuxiliary<V: View>(title: String, size: NSSize, @ViewBuilder content: (@escaping () -> Void) -> V) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        let close: () -> Void = { [weak window, weak self] in
            window?.close()
            self?.auxiliaryWindows.removeAll { $0 === window }
        }
        window.contentViewController = NSHostingController(rootView: content(close).frame(minWidth: size.width, minHeight: size.height))
        window.center()
        auxiliaryWindows.append(window)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: Workspaces

    @discardableResult
    func openWorkspace(_ config: ConnectionConfig, secrets: ConnectionSecrets? = nil, restoring state: WorkspaceSession.State? = nil) -> WorkspaceWindowController {
        let controller = WorkspaceWindowController(config: config, secrets: secrets ?? Keychain.secrets(for: config.id), state: state)
        controller.onClose = { [weak self, weak controller] in
            self?.workspaces.removeAll { $0 === controller }
            if self?.workspaces.isEmpty == true, NSApp.isRunning { self?.showWelcome(nil) }
        }
        workspaces.append(controller)
        if let host = NSApp.keyWindow as? WorkspaceWindow, let w = controller.window {
            host.addTabbedWindow(w, ordered: .above)
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        if ConnectionStore.shared.connection(config.id) != nil { ConnectionStore.shared.markConnected(config.id) }
        return controller
    }

    func open(_ url: URL) {
        if url.isFileURL {
            let ext = url.pathExtension.lowercased()
            if ext == "sql" || ext == "psql" {
                let sql = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                if let ws = (NSApp.keyWindow?.windowController as? WorkspaceWindowController) ?? workspaces.last {
                    ws.model.openQueryTab(title: url.lastPathComponent, sql: sql, run: false, fileURL: url)
                } else {
                    showWelcome(nil)
                }
                return
            }
            var c = ConnectionConfig(name: url.lastPathComponent, driver: .sqlite)
            c.filePath = url.path
            if let existing = ConnectionStore.shared.connections.first(where: { $0.driver == .sqlite && $0.filePath == url.path }) { c = existing }
            openWorkspace(c, secrets: ConnectionSecrets())
            return
        }
        guard let (config, secrets) = ConnectionURL.parse(url.absoluteString) else { return }
        openWorkspace(config, secrets: secrets)
    }

    private func restoreWorkspacesIfNeeded() -> Bool {
        guard UserDefaults.standard.bool(forKey: SettingKey.restoreWorkspaces), ProcessInfo.processInfo.environment["MTP_NO_RESTORE"] == nil else { return false }
        let states = WorkspaceSession.load()
        var opened = false
        for state in states {
            guard let config = ConnectionStore.shared.connection(state.connectionID) else { continue }
            openWorkspace(config, restoring: state)
            opened = true
        }
        return opened
    }
}

extension Notification.Name {
    static let mtpFontSizeChanged = Notification.Name("MTPFontSizeChanged")
    /// Scrolls the open connection form to a section ("ssh", "aws"…); used by automation.
    static let mtpConnectionFormScroll = Notification.Name("MTPConnectionFormScroll")
}
