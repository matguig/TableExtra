import AppKit
import MTPCore
import SwiftUI

@MainActor
final class WorkspaceWindowController: NSWindowController, NSWindowDelegate {
    let model: WorkspaceModel
    var onClose: (() -> Void)?

    init(config: ConnectionConfig, secrets: ConnectionSecrets, state: WorkspaceSession.State?) {
        model = WorkspaceModel(config: config, secrets: secrets, state: state)
        let window = WorkspaceWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 820),
                                     styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                     backing: .buffered, defer: false)
        window.model = model
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "TableExtraWorkspace"
        window.minSize = NSSize(width: 820, height: 480)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("WorkspaceWindow")
        super.init(window: window)
        window.title = Self.title(for: config)
        window.subtitle = config.subtitle
        window.tab.title = config.name
        let host = NSHostingController(rootView: WorkspaceView(model: model))
        host.sceneBridgingOptions = [.toolbars]
        window.contentViewController = host
        window.toolbarStyle = .unified
        window.delegate = self
        model.window = window
        model.windowWidth = window.frame.width
        if window.frame.width < 900 { window.setContentSize(NSSize(width: 1320, height: 820)); window.center() }
        Task { await model.connect() }
    }

    required init?(coder: NSCoder) { fatalError() }

    static func title(for c: ConnectionConfig) -> String {
        c.isProductionLike ? "\(c.environment.displayName.uppercased()) · \(c.name)" : c.name
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.hasUnsavedChanges else { return true }
        let alert = NSAlert()
        alert.messageText = "Close \(model.connection.name)?"
        alert.informativeText = "Some tabs have uncommitted changes or an open transaction."
        alert.addButton(withTitle: "Close Anyway")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func windowDidResize(_ notification: Notification) {
        if let w = window?.frame.width, abs(w - model.windowWidth) > 1 { model.windowWidth = w }
    }

    func windowWillClose(_ notification: Notification) {
        WorkspaceSession.save(AppDelegate.shared.workspaces.filter { $0 !== self }.map(\.model) + [model], closing: model)
        model.disconnect()
        onClose?()
    }
}

/// Menu actions land here through the responder chain and are routed to the current tab.
@MainActor
final class WorkspaceWindow: NSWindow, MTPActions {
    weak var model: WorkspaceModel?

    private var table: TableTabModel? { model?.selectedTab as? TableTabModel }
    private var query: QueryTabModel? { model?.selectedTab as? QueryTabModel }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let model, let action = item.action else { return super.validateMenuItem(item) }
        let editableTable = table.map { $0.isEditable && $0.mode == .data } ?? false
        switch action {
        case #selector(runCurrentQuery(_:)), #selector(runAllQueries(_:)), #selector(explainQuery(_:)), #selector(formatSQL(_:)),
             #selector(toggleLineComment(_:)), #selector(toggleBlockComment(_:)), #selector(saveQueryAs(_:)), #selector(saveAsFavorite(_:)),
             #selector(saveQuery(_:)):
            return query != nil
        case #selector(cancelQuery(_:)):
            return query?.isRunning == true || model.client.isBusy
        case #selector(addRow(_:)), #selector(duplicateRows(_:)):
            return editableTable
        case #selector(deleteRows(_:)), #selector(setNull(_:)):
            return editableTable && !(table?.selectedRows.isEmpty ?? true)
        case #selector(commitChanges(_:)):
            return table?.hasUnsavedChanges == true || query != nil
        case #selector(previewChanges(_:)), #selector(discardChanges(_:)):
            return table?.hasUnsavedChanges == true
        case #selector(showTableData(_:)), #selector(showTableStructure(_:)), #selector(toggleFilters(_:)):
            return table != nil
        case #selector(copyRows(_:)), #selector(copyAsCSV(_:)), #selector(copyAsJSON(_:)), #selector(copyAsInsert(_:)), #selector(copyAsMarkdown(_:)):
            return table != nil
        case #selector(switchDatabase(_:)):
            return model.connection.driver == .postgres
        case #selector(showProcessList(_:)), #selector(backupDatabase(_:)), #selector(restoreDatabase(_:)):
            return true
        case #selector(setSafetyLevel(_:)):
            item.state = item.tag == model.connection.safety.rawValue ? .on : .off
            return true
        case #selector(selectTabAtIndex(_:)):
            return item.tag < model.tabs.count
        case #selector(toggleLeftSidebar(_:)):
            item.title = model.showLeftSidebar ? "Hide Left Sidebar" : "Show Left Sidebar"
            return true
        case #selector(toggleRightSidebar(_:)):
            item.title = model.showRightSidebar ? "Hide Right Sidebar" : "Show Right Sidebar"
            return true
        default:
            return super.validateMenuItem(item)
        }
    }

    // MARK: Tabs & navigation

    @objc func newQueryTab(_ sender: Any?) { model?.openQueryTab(title: nil, sql: "", run: false) }
    @objc func closeTab(_ sender: Any?) {
        if let id = model?.selectedTabID { model?.closeTab(id) } else { performClose(nil) }
    }
    @objc func nextTab(_ sender: Any?) { model?.selectNextTab(1) }
    @objc func previousTab(_ sender: Any?) { model?.selectNextTab(-1) }
    @objc func selectTabAtIndex(_ sender: Any?) {
        guard let model, let tag = (sender as? NSMenuItem)?.tag, tag < model.tabs.count else { return }
        model.select(model.tabs[tag].id)
    }
    @objc func goBack(_ sender: Any?) { model?.goBack() }
    @objc func goForward(_ sender: Any?) { model?.goForward() }
    @objc func openAnything(_ sender: Any?) { model?.overlay = model?.overlay == .openAnything ? nil : .openAnything }
    @objc func commandPalette(_ sender: Any?) { model?.overlay = model?.overlay == .commandPalette ? nil : .commandPalette }
    @objc func switchDatabase(_ sender: Any?) { model?.overlay = .databaseSwitcher }
    @objc func switchSchema(_ sender: Any?) { model?.overlay = .schemaSwitcher }
    @objc func toggleLeftSidebar(_ sender: Any?) { model?.showLeftSidebar.toggle() }
    @objc func toggleRightSidebar(_ sender: Any?) { model?.showRightSidebar.toggle() }
    @objc func toggleConsole(_ sender: Any?) { model?.showConsole.toggle() }
    @objc func toggleResultsPane(_ sender: Any?) { query?.showResults.toggle() }
    @objc func showTableData(_ sender: Any?) { table?.mode = .data }
    @objc func showTableStructure(_ sender: Any?) { table?.mode = .structure }

    @objc func findAnything(_ sender: Any?) {
        if let q = query, let tv = q.textView {
            makeFirstResponder(tv)
            let item = NSMenuItem()
            item.tag = NSTextFinder.Action.showFindInterface.rawValue
            tv.performFindPanelAction(item)
        } else if let t = table {
            t.showFilters = true
            if t.filters.isEmpty { t.filters = [FilterRule(column: nil, op: .containsCaseInsensitive)] }
        } else {
            model?.showLeftSidebar = true
            NotificationCenter.default.post(name: .mtpFocusSidebarSearch, object: model)
        }
    }

    @objc func toggleFilters(_ sender: Any?) {
        guard let t = table else { return }
        t.showFilters.toggle()
        if t.showFilters && t.filters.isEmpty { t.filters = [FilterRule(column: t.columns.first?.name)] }
    }

    // MARK: Connection

    @objc func editCurrentConnection(_ sender: Any?) { model?.sheet = .editConnection }
    @objc func reloadWorkspace(_ sender: Any?) { Task { await model?.reloadWorkspace() } }
    @objc func reloadCurrentTab(_ sender: Any?) {
        if let t = table { Task { await t.reloadAll() } } else { Task { await model?.loadObjects() } }
    }
    @objc func reconnect(_ sender: Any?) { Task { await model?.reconnect() } }
    @objc func disconnect(_ sender: Any?) { performClose(nil) }
    @objc func runCurrentQuery(_ sender: Any?) { if let q = query { Task { await q.runCurrent() } } }
    @objc func runAllQueries(_ sender: Any?) { if let q = query { Task { await q.runAll() } } }
    @objc func cancelQuery(_ sender: Any?) {
        if let q = query, q.isRunning { q.cancel() } else { model?.client.cancel() }
    }
    @objc func explainQuery(_ sender: Any?) { query?.explainCurrent() }
    @objc func formatSQL(_ sender: Any?) { query?.format() }
    @objc func toggleLineComment(_ sender: Any?) { query?.textView?.toggleLineComment() }
    @objc func toggleBlockComment(_ sender: Any?) { query?.textView?.toggleBlockComment() }
    @objc func saveQuery(_ sender: Any?) { query?.save(choosingLocation: query?.fileURL == nil) }
    @objc func saveQueryAs(_ sender: Any?) { query?.save(choosingLocation: true) }
    @objc func saveAsFavorite(_ sender: Any?) { query?.saveAsFavorite() }

    @objc func setSafetyLevel(_ sender: Any?) {
        guard let model, let tag = (sender as? NSMenuItem)?.tag, let level = SafetyLevel(rawValue: tag) else { return }
        Task {
            // Lowering protection on production requires authentication.
            if model.connection.isProductionLike, level.rawValue < model.connection.safety.rawValue,
               !(await SafetyGate.authenticate(reason: "lower the safety level of \(model.connection.name)")) { return }
            var c = model.connection
            c.safety = level
            model.updateConnection(c)
            model.showToast("Safety: \(level.displayName)")
        }
    }

    // MARK: Data editing

    @objc func commitChanges(_ sender: Any?) {
        if let t = table { Task { await t.commit() } } else if let q = query { q.save(choosingLocation: q.fileURL == nil) }
    }
    @objc func previewChanges(_ sender: Any?) {
        guard let t = table else { return }
        model?.sheet = .preview(title: "Pending changes — \(t.object.name)", sql: t.previewSQL())
    }
    @objc func discardChanges(_ sender: Any?) { table?.discard() }
    @objc func addRow(_ sender: Any?) { table?.addRow() }
    @objc func duplicateRows(_ sender: Any?) { if let t = table { t.duplicateRows(t.selectedRows) } }
    @objc func deleteRows(_ sender: Any?) { if let t = table { t.deleteRows(t.selectedRows) } }
    @objc func setNull(_ sender: Any?) {
        guard let t = table, let c = t.focusedColumn else { return }
        for r in t.selectedRows { t.setValue(.null, row: r, column: c) }
    }
    @objc func copyRows(_ sender: Any?) { table?.copySelection(as: .tsv) }
    @objc func copyAsCSV(_ sender: Any?) { table?.copySelection(as: .csv) }
    @objc func copyAsJSON(_ sender: Any?) { table?.copySelection(as: .json) }
    @objc func copyAsInsert(_ sender: Any?) { table?.copySelection(as: .sqlInsert) }
    @objc func copyAsMarkdown(_ sender: Any?) { table?.copySelection(as: .markdown) }

    // MARK: Tools

    @objc func showProcessList(_ sender: Any?) { model?.openFeature(.processList) }
    @objc func showInsights(_ sender: Any?) { model?.openFeature(.insights) }
    @objc func showRDS(_ sender: Any?) { model?.openFeature(.rds) }
    @objc func showDiagram(_ sender: Any?) { if let m = model { m.openFeature(.diagram(schema: m.currentSchema)) } }
    @objc func showSchemaDiff(_ sender: Any?) { model?.openFeature(.schemaDiff) }
    @objc func generateTypeScript(_ sender: Any?) { if let m = model { m.openFeature(.typeScript(schema: m.currentSchema, tables: nil)) } }
    @objc func showHistory(_ sender: Any?) { model?.sidebarMode = .history; model?.showLeftSidebar = true }
    @objc func showFavorites(_ sender: Any?) { model?.sidebarMode = .favorites; model?.showLeftSidebar = true }
    @objc func searchInDatabase(_ sender: Any?) { model?.openFeature(.databaseSearch) }
    @objc func showAIAssistant(_ sender: Any?) {
        guard let model else { return }
        model.toggleClaude()
    }
    @objc func exportData(_ sender: Any?) {
        guard let model else { return }
        if let t = table {
            model.sheet = .export(.tables(schema: t.object.schema, names: [t.object.name]))
        } else {
            let names = model.objects.filter { $0.kind == .table }.map(\.name)
            model.sheet = .export(.tables(schema: model.currentSchema, names: names))
        }
    }
    @objc func importCSV(_ sender: Any?) {
        guard let model else { return }
        model.sheet = .importCSV(schema: table?.object.schema ?? model.currentSchema, table: table?.object.name)
    }
    @objc func backupDatabase(_ sender: Any?) { model?.sheet = .backup }
    @objc func restoreDatabase(_ sender: Any?) { model?.sheet = .restore }
}

extension Notification.Name {
    static let mtpFocusSidebarSearch = Notification.Name("MTPFocusSidebarSearch")
}
