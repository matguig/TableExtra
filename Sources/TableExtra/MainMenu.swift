import AppKit

/// Every menu action that targets the first responder. Implemented by `WorkspaceWindow`
/// (and partly by the app delegate). Keeping them in one protocol makes `#selector` checked.
@MainActor @objc protocol MTPActions {
    // App
    @objc optional func showSettings(_ sender: Any?)
    @objc optional func showWelcome(_ sender: Any?)
    @objc optional func newConnection(_ sender: Any?)
    @objc optional func importFromTablePlus(_ sender: Any?)
    @objc optional func openDocument(_ sender: Any?)
    @objc optional func openConnectionURL(_ sender: Any?)
    // Workspace / tabs
    @objc optional func newQueryTab(_ sender: Any?)
    @objc optional func closeTab(_ sender: Any?)
    @objc optional func nextTab(_ sender: Any?)
    @objc optional func previousTab(_ sender: Any?)
    @objc optional func selectTabAtIndex(_ sender: Any?)
    @objc optional func goBack(_ sender: Any?)
    @objc optional func goForward(_ sender: Any?)
    @objc optional func openAnything(_ sender: Any?)
    @objc optional func commandPalette(_ sender: Any?)
    @objc optional func findAnything(_ sender: Any?)
    @objc optional func toggleLeftSidebar(_ sender: Any?)
    @objc optional func toggleRightSidebar(_ sender: Any?)
    @objc optional func toggleResultsPane(_ sender: Any?)
    @objc optional func toggleConsole(_ sender: Any?)
    @objc optional func showTableData(_ sender: Any?)
    @objc optional func showTableStructure(_ sender: Any?)
    // Connection
    @objc optional func switchDatabase(_ sender: Any?)
    @objc optional func switchSchema(_ sender: Any?)
    @objc optional func editCurrentConnection(_ sender: Any?)
    @objc optional func reloadWorkspace(_ sender: Any?)
    @objc optional func reloadCurrentTab(_ sender: Any?)
    @objc optional func reconnect(_ sender: Any?)
    @objc optional func disconnect(_ sender: Any?)
    @objc optional func runCurrentQuery(_ sender: Any?)
    @objc optional func runAllQueries(_ sender: Any?)
    @objc optional func cancelQuery(_ sender: Any?)
    @objc optional func explainQuery(_ sender: Any?)
    @objc optional func formatSQL(_ sender: Any?)
    @objc optional func saveQuery(_ sender: Any?)
    @objc optional func saveQueryAs(_ sender: Any?)
    @objc optional func saveAsFavorite(_ sender: Any?)
    // Data editing
    @objc optional func commitChanges(_ sender: Any?)
    @objc optional func previewChanges(_ sender: Any?)
    @objc optional func discardChanges(_ sender: Any?)
    @objc optional func addRow(_ sender: Any?)
    @objc optional func duplicateRows(_ sender: Any?)
    @objc optional func deleteRows(_ sender: Any?)
    @objc optional func setNull(_ sender: Any?)
    @objc optional func copyRows(_ sender: Any?)
    @objc optional func copyAsCSV(_ sender: Any?)
    @objc optional func copyAsJSON(_ sender: Any?)
    @objc optional func copyAsInsert(_ sender: Any?)
    @objc optional func copyAsMarkdown(_ sender: Any?)
    @objc optional func toggleFilters(_ sender: Any?)
    @objc optional func toggleLineComment(_ sender: Any?)
    @objc optional func toggleBlockComment(_ sender: Any?)
    // Tools
    @objc optional func showProcessList(_ sender: Any?)
    @objc optional func showInsights(_ sender: Any?)
    @objc optional func showDiagram(_ sender: Any?)
    @objc optional func showSchemaDiff(_ sender: Any?)
    @objc optional func generateTypeScript(_ sender: Any?)
    @objc optional func showAIAssistant(_ sender: Any?)
    @objc optional func showRDS(_ sender: Any?)
    @objc optional func exportData(_ sender: Any?)
    @objc optional func importCSV(_ sender: Any?)
    @objc optional func backupDatabase(_ sender: Any?)
    @objc optional func restoreDatabase(_ sender: Any?)
    @objc optional func searchInDatabase(_ sender: Any?)
    @objc optional func showHistory(_ sender: Any?)
    @objc optional func showFavorites(_ sender: Any?)
    @objc optional func setSafetyLevel(_ sender: Any?)
    @objc optional func setAppearance(_ sender: Any?)
    @objc optional func increaseFontSize(_ sender: Any?)
    @objc optional func decreaseFontSize(_ sender: Any?)
    @objc optional func showHelp(_ sender: Any?)
    @objc optional func showReverseEngineeringNotes(_ sender: Any?)
}

enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu(title: "Main Menu")

        // TableExtra
        let app = submenu(main, "TableExtra")
        app.addItem(withTitle: "About TableExtra", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(item("Settings…", #selector(MTPActions.showSettings(_:)), ","))
        app.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: "Services")
        NSApp.servicesMenu = services.submenu
        app.addItem(services)
        app.addItem(.separator())
        app.addItem(withTitle: "Hide TableExtra", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit TableExtra", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File
        let file = submenu(main, "File")
        file.addItem(item("New Workspace…", #selector(MTPActions.showWelcome(_:)), "n"))
        file.addItem(item("New Connection…", #selector(MTPActions.newConnection(_:)), "n", [.command, .shift]))
        file.addItem(item("New Query Tab", #selector(MTPActions.newQueryTab(_:)), "t"))
        file.addItem(item("Open…", #selector(MTPActions.openDocument(_:)), "o"))
        file.addItem(item("Open Connection URL…", #selector(MTPActions.openConnectionURL(_:)), "o", [.command, .shift]))
        file.addItem(.separator())
        file.addItem(item("Close Tab", #selector(MTPActions.closeTab(_:)), "w"))
        file.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift]))
        file.addItem(.separator())
        file.addItem(item("Save Query…", #selector(MTPActions.saveQuery(_:)), ""))
        file.addItem(item("Save Query As…", #selector(MTPActions.saveQueryAs(_:)), "s", [.command, .shift]))
        file.addItem(item("Save as Favorite…", #selector(MTPActions.saveAsFavorite(_:)), "s", [.command, .option]))
        file.addItem(.separator())
        file.addItem(item("Export…", #selector(MTPActions.exportData(_:)), "e"))
        let imp = NSMenuItem(title: "Import", action: nil, keyEquivalent: "")
        let impMenu = NSMenu(title: "Import")
        impMenu.addItem(item("From CSV / JSON…", #selector(MTPActions.importCSV(_:)), ""))
        impMenu.addItem(item("From SQL Dump (Restore)…", #selector(MTPActions.restoreDatabase(_:)), ""))
        impMenu.addItem(item("Connections from TablePlus…", #selector(MTPActions.importFromTablePlus(_:)), ""))
        imp.submenu = impMenu
        file.addItem(imp)
        file.addItem(item("Backup…", #selector(MTPActions.backupDatabase(_:)), ""))
        file.addItem(item("Restore…", #selector(MTPActions.restoreDatabase(_:)), ""))

        // Edit
        let edit = submenu(main, "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(item("Copy Rows", #selector(MTPActions.copyRows(_:)), "c", [.command, .shift]))
        let copyAs = NSMenuItem(title: "Copy As", action: nil, keyEquivalent: "")
        let copyAsMenu = NSMenu(title: "Copy As")
        copyAsMenu.addItem(item("CSV", #selector(MTPActions.copyAsCSV(_:)), ""))
        copyAsMenu.addItem(item("JSON", #selector(MTPActions.copyAsJSON(_:)), ""))
        copyAsMenu.addItem(item("SQL INSERT", #selector(MTPActions.copyAsInsert(_:)), ""))
        copyAsMenu.addItem(item("Markdown", #selector(MTPActions.copyAsMarkdown(_:)), ""))
        copyAs.submenu = copyAsMenu
        edit.addItem(copyAs)
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(item("Add Row", #selector(MTPActions.addRow(_:)), "i"))
        edit.addItem(item("Duplicate Rows", #selector(MTPActions.duplicateRows(_:)), "d"))
        edit.addItem(item("Delete Rows", #selector(MTPActions.deleteRows(_:)), "\u{8}"))
        edit.addItem(item("Set NULL", #selector(MTPActions.setNull(_:)), "n", [.command, .option]))
        edit.addItem(.separator())
        edit.addItem(item("Commit Changes", #selector(MTPActions.commitChanges(_:)), "s"))
        edit.addItem(item("Preview Changes", #selector(MTPActions.previewChanges(_:)), "p", [.command, .shift]))
        edit.addItem(item("Discard Changes", #selector(MTPActions.discardChanges(_:)), "\u{8}", [.command, .shift]))
        edit.addItem(.separator())
        let find = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        let findMenu = NSMenu(title: "Find")
        findMenu.addItem(item("Find…", #selector(MTPActions.findAnything(_:)), "f"))
        findMenu.addItem(tagged("Find and Replace…", #selector(NSTextView.performFindPanelAction(_:)), "f", [.command, .option], NSTextFinder.Action.showReplaceInterface.rawValue))
        findMenu.addItem(tagged("Find Next", #selector(NSTextView.performFindPanelAction(_:)), "g", [.command], NSTextFinder.Action.nextMatch.rawValue))
        findMenu.addItem(tagged("Find Previous", #selector(NSTextView.performFindPanelAction(_:)), "g", [.command, .shift], NSTextFinder.Action.previousMatch.rawValue))
        findMenu.addItem(tagged("Use Selection for Find", #selector(NSTextView.performFindPanelAction(_:)), "", [.command], NSTextFinder.Action.setSearchString.rawValue))
        find.submenu = findMenu
        edit.addItem(find)
        edit.addItem(item("Filter Rows", #selector(MTPActions.toggleFilters(_:)), "f", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item("Toggle Line Comment", #selector(MTPActions.toggleLineComment(_:)), "/"))
        edit.addItem(item("Toggle Block Comment", #selector(MTPActions.toggleBlockComment(_:)), "/", [.command, .option]))
        edit.addItem(item("Format SQL", #selector(MTPActions.formatSQL(_:)), "i", [.control]))
        let transform = NSMenuItem(title: "Transformations", action: nil, keyEquivalent: "")
        let transformMenu = NSMenu(title: "Transformations")
        transformMenu.addItem(withTitle: "Make Upper Case", action: #selector(NSTextView.uppercaseWord(_:)), keyEquivalent: "")
        transformMenu.addItem(withTitle: "Make Lower Case", action: #selector(NSTextView.lowercaseWord(_:)), keyEquivalent: "")
        transformMenu.addItem(withTitle: "Capitalize", action: #selector(NSTextView.capitalizeWord(_:)), keyEquivalent: "")
        transform.submenu = transformMenu
        edit.addItem(transform)

        // View
        let view = submenu(main, "View")
        view.addItem(item("Table Data", #selector(MTPActions.showTableData(_:)), "[", [.command, .control]))
        view.addItem(item("Table Structure", #selector(MTPActions.showTableStructure(_:)), "]", [.command, .control]))
        view.addItem(.separator())
        view.addItem(item("Toggle Left Sidebar", #selector(MTPActions.toggleLeftSidebar(_:)), "0"))
        view.addItem(item("Toggle Right Sidebar", #selector(MTPActions.toggleRightSidebar(_:)), "0", [.command, .option]))
        view.addItem(item("Toggle Query Results", #selector(MTPActions.toggleResultsPane(_:)), "`", [.control]))
        view.addItem(item("Toggle Console Log", #selector(MTPActions.toggleConsole(_:)), "c", [.command, .control]))
        view.addItem(.separator())
        view.addItem(item("Increase Font Size", #selector(MTPActions.increaseFontSize(_:)), "="))
        view.addItem(item("Decrease Font Size", #selector(MTPActions.decreaseFontSize(_:)), "-"))
        let appearance = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        let appearanceMenu = NSMenu(title: "Appearance")
        for (title, value) in [("System", "system"), ("Light", "light"), ("Dark", "dark")] {
            let i = item(title, #selector(MTPActions.setAppearance(_:)), "")
            i.representedObject = value
            appearanceMenu.addItem(i)
        }
        appearance.submenu = appearanceMenu
        view.addItem(appearance)
        view.addItem(.separator())
        view.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))

        // Connection
        let conn = submenu(main, "Connection")
        conn.addItem(item("Open a Connection…", #selector(MTPActions.showWelcome(_:)), "k", [.command, .shift]))
        conn.addItem(item("Open a Database…", #selector(MTPActions.switchDatabase(_:)), "k"))
        conn.addItem(item("Switch Schema…", #selector(MTPActions.switchSchema(_:)), "k", [.command, .option]))
        conn.addItem(item("Edit Connection…", #selector(MTPActions.editCurrentConnection(_:)), ""))
        conn.addItem(.separator())
        conn.addItem(item("Run Current Query", #selector(MTPActions.runCurrentQuery(_:)), "\r"))
        conn.addItem(item("Run All Queries", #selector(MTPActions.runAllQueries(_:)), "\r", [.command, .shift]))
        conn.addItem(item("Explain Query", #selector(MTPActions.explainQuery(_:)), "e", [.command, .option]))
        conn.addItem(item("Cancel Running Query", #selector(MTPActions.cancelQuery(_:)), "."))
        conn.addItem(.separator())
        conn.addItem(item("Reload Workspace", #selector(MTPActions.reloadWorkspace(_:)), "r"))
        conn.addItem(item("Reload Current Tab", #selector(MTPActions.reloadCurrentTab(_:)), "r", [.command, .option]))
        conn.addItem(item("Reconnect", #selector(MTPActions.reconnect(_:)), "r", [.command, .shift]))
        conn.addItem(item("Disconnect", #selector(MTPActions.disconnect(_:)), ".", [.command, .option]))
        conn.addItem(.separator())
        let safety = NSMenuItem(title: "Safety Level", action: nil, keyEquivalent: "")
        let safetyMenu = NSMenu(title: "Safety Level")
        for level in [0, 1, 2, 3] {
            let titles = ["Silent", "Warning — confirm writes", "Safe — Touch ID for writes", "Read-only"]
            let i = item(titles[level], #selector(MTPActions.setSafetyLevel(_:)), "")
            i.tag = level
            safetyMenu.addItem(i)
        }
        safety.submenu = safetyMenu
        conn.addItem(safety)

        // Tools
        let tools = submenu(main, "Tools")
        tools.addItem(item("Ask AI…", #selector(MTPActions.showAIAssistant(_:)), "l"))
        tools.addItem(item("AWS RDS Monitoring", #selector(MTPActions.showRDS(_:)), ""))
        tools.addItem(item("Database Insights", #selector(MTPActions.showInsights(_:)), "i", [.command, .option]))
        tools.addItem(item("Process List", #selector(MTPActions.showProcessList(_:)), "l", [.command, .option]))
        tools.addItem(item("ER Diagram", #selector(MTPActions.showDiagram(_:)), "d", [.command, .option]))
        tools.addItem(item("Schema Diff…", #selector(MTPActions.showSchemaDiff(_:)), ""))
        tools.addItem(item("Generate Kysely / TypeScript Types…", #selector(MTPActions.generateTypeScript(_:)), "t", [.command, .option]))
        tools.addItem(item("Search in Database…", #selector(MTPActions.searchInDatabase(_:)), "f", [.command, .option, .shift]))
        tools.addItem(.separator())
        tools.addItem(item("Query History", #selector(MTPActions.showHistory(_:)), "y"))
        tools.addItem(item("Favorites", #selector(MTPActions.showFavorites(_:)), "y", [.command, .shift]))

        // Navigate
        let nav = submenu(main, "Navigate")
        nav.addItem(item("Open Anything", #selector(MTPActions.openAnything(_:)), "p"))
        nav.addItem(item("Command Palette", #selector(MTPActions.commandPalette(_:)), "p", [.command, .option]))
        nav.addItem(.separator())
        nav.addItem(item("Select Next Tab", #selector(MTPActions.nextTab(_:)), "]"))
        nav.addItem(item("Select Previous Tab", #selector(MTPActions.previousTab(_:)), "["))
        nav.addItem(item("Select Next Workspace", #selector(NSWindow.selectNextTab(_:)), "]", [.command, .shift]))
        nav.addItem(item("Select Previous Workspace", #selector(NSWindow.selectPreviousTab(_:)), "[", [.command, .shift]))
        nav.addItem(item("Go Back", #selector(MTPActions.goBack(_:)), String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.command, .control]))
        nav.addItem(item("Go Forward", #selector(MTPActions.goForward(_:)), String(UnicodeScalar(NSRightArrowFunctionKey)!), [.command, .control]))
        nav.addItem(.separator())
        for i in 1...9 {
            let t = item("Tab \(i)", #selector(MTPActions.selectTabAtIndex(_:)), String(i))
            t.tag = i - 1
            nav.addItem(t)
        }

        // Window
        let window = submenu(main, "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window

        // Help
        let help = submenu(main, "Help")
        help.addItem(item("TableExtra Help", #selector(MTPActions.showHelp(_:)), "?"))
        help.addItem(item("TablePlus Reverse-Engineering Notes", #selector(MTPActions.showReverseEngineeringNotes(_:)), ""))
        NSApp.helpMenu = help
        return main
    }

    private static func submenu(_ main: NSMenu, _ title: String) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu
        main.addItem(item)
        return menu
    }

    private static func item(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = key.isEmpty ? [] : mods
        return i
    }

    private static func tagged(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags, _ tag: Int) -> NSMenuItem {
        let i = item(title, action, key, mods)
        i.tag = tag
        return i
    }
}
