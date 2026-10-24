import AppKit
import FeatureInsights
import MTPCore
import MTPUIKit

/// Scriptable hooks for automated UI checks (`scripts/mtpctl`), off unless MTP_AUTOMATION=1.
/// Commands arrive as distributed notifications named "fr.koa-dev.TableExtra.automation"
/// whose `object` is the command string, e.g. "snapshot:/tmp/a.png", "connect:Shop", "table:public.orders".
@MainActor
final class DebugAutomation {
    static let shared = DebugAutomation()
    /// MTP_AUTOMATION_ID isolates instances so parallel test runs don't receive each other's commands.
    static let notification = Notification.Name("fr.koa-dev.TableExtra.automation"
        + (ProcessInfo.processInfo.environment["MTP_AUTOMATION_ID"].map { "." + $0 } ?? ""))
    private var observer: Any?

    func start() {
        guard ProcessInfo.processInfo.environment["MTP_AUTOMATION"] == "1" else { return }
        observer = DistributedNotificationCenter.default().addObserver(forName: Self.notification, object: nil, queue: .main) { n in
            guard let command = n.object as? String else { return }
            MainActor.assumeIsolated { DebugAutomation.shared.handle(command) }
        }
    }

    private var workspace: WorkspaceModel? {
        (NSApp.keyWindow as? WorkspaceWindow)?.model ?? AppDelegate.shared.workspaces.last?.model
    }

    func handle(_ command: String) {
        let parts = command.split(separator: ":", maxSplits: 1).map(String.init)
        let verb = parts[0]
        let arg = parts.count > 1 ? parts[1] : ""
        switch verb {
        case "snapshot":
            snapshot(to: arg)
        case "connect":
            if let c = ConnectionStore.shared.find(arg) {
                AppDelegate.shared.openWorkspace(c)
                AppDelegate.shared.closeWelcome()
            }
        case "welcome":
            AppDelegate.shared.showWelcome(nil)
        case "table":
            let p = arg.split(separator: ".", maxSplits: 1).map(String.init)
            if p.count == 2 { workspace?.openTable(schema: p[0], name: p[1]) }
        case "structure":
            (workspace?.selectedTab as? TableTabModel)?.mode = .structure
        case "query":
            workspace?.openQueryTab(title: nil, sql: arg.replacingOccurrences(of: "\\n", with: "\n"), run: false)
        case "run":
            if let q = workspace?.selectedTab as? QueryTabModel { Task { await q.runAll() } }
        case "feature":
            switch arg {
            case "insights": workspace?.openFeature(.insights)
            case "processes": workspace?.openFeature(.processList)
            case "diagram": if let w = workspace { w.openFeature(.diagram(schema: w.currentSchema)) }
            case "diff": workspace?.openFeature(.schemaDiff)
            case "typescript": if let w = workspace { w.openFeature(.typeScript(schema: w.currentSchema, tables: nil)) }
            case "search": workspace?.openFeature(.databaseSearch)
            case "rds": workspace?.openFeature(.rds)
            case "history": workspace?.openFeature(.history)
            default: break
            }
        case "overlay":
            workspace?.overlay = arg == "palette" ? .commandPalette : .openAnything
        case "editconnection":
            workspace?.sheet = .editConnection
        case "scroll":
            // scroll:<fraction 0…1> of the largest scroll view in the key window.
            scroll(to: Double(arg) ?? 1)
        case "awsgrant":
            // Same as picking the folder in the open panel.
            AWSConfigFolder.grant(URL(fileURLWithPath: (arg as NSString).expandingTildeInPath, isDirectory: true))
        case "formscroll":
            NotificationCenter.default.post(name: .mtpConnectionFormScroll, object: arg)
        case "dismiss":
            workspace?.overlay = nil
            workspace?.sheet = nil
        case "filter":
            if let t = workspace?.selectedTab as? TableTabModel {
                let p = arg.split(separator: "=", maxSplits: 1).map(String.init)
                if p.count == 2 { t.addQuickFilter(FilterRule(column: p[0], op: .equals, value: p[1])) }
            }
        case "edit":
            // edit:row,col,value — stages a change in the current table tab
            if let t = workspace?.selectedTab as? TableTabModel {
                let p = arg.split(separator: ",", maxSplits: 2).map(String.init)
                if p.count == 3, let r = Int(p[0]), let c = Int(p[1]) { t.setValue(.value(p[2]), row: r, column: c) }
            }
        case "select":
            if let t = workspace?.selectedTab as? TableTabModel, let r = Int(arg) { t.selectedRows = IndexSet(integer: r); t.dataVersion += 1 }
        case "chart":
            // chart:bar|line|area|point|pie — show the current query result as a chart of that kind.
            if let q = workspace?.selectedTab as? QueryTabModel, let item = q.results.first(where: { $0.id == q.selectedResultID }) ?? q.results.last,
               case .rows(let r) = item.kind {
                q.chartResults.insert(item.id)
                var c = q.chartConfigs[item.id] ?? ChartData.suggest(for: r)
                if let kind = ChartKind(rawValue: arg) { c.kind = kind }
                q.chartConfigs[item.id] = c
            }
        case "claudepending":
            // Opens Claude with a table attached, without sending (no real call).
            if let w = workspace, let t = w.selectedTab as? TableTabModel {
                let cols = t.columns.map { "\($0.name) \($0.typeName)" }.joined(separator: "\n")
                w.askClaude(AIRequest(title: "Query on \(t.object.name)", prompt: "",
                                      attachments: [AIAttachments.text(cols, title: t.object.qualifiedName, systemImage: "tablecells")],
                                      focus: t.object.name, autoSend: false))
            }
        case "claudeask":
            // Sends a question to Claude right away (a real call when the backend is configured).
            workspace?.askClaude(AIRequest(title: "Question", prompt: arg, attachments: [], focus: "", autoSend: true))
        case "sidebarfilter":
            workspace?.sidebarFilter = arg
        case "pin":
            if let w = workspace, let o = w.objects.first(where: { $0.name == arg }) { w.togglePin(o) }
        case "expandall":
            if let w = workspace {
                var ids = Set<String>()
                func walk(_ n: ObjectGrouping.Node) {
                    if case .group(let id, _, _, let children) = n { ids.insert(id); children.forEach(walk) }
                }
                for kind in DBObjectKind.allCases {
                    ObjectGrouping.nodes(for: w.objects.filter { $0.kind == kind }, prefixFolders: w.groupByPrefix).forEach(walk)
                }
                w.expandedGroups = arg.isEmpty ? ids : ids.filter { $0.hasSuffix("." + arg) || $0.contains(arg) }
            }
        case "sidebar":
            workspace?.sidebarMode = arg == "history" ? .history : (arg == "queries" ? .favorites : .items)
        case "rightsidebar":
            workspace?.showRightSidebar = arg != "off"
        case "ai":
            if let w = workspace, (arg != "off") != w.isClaudeOpen { w.toggleClaude() }
        case "action":
            // Target the workspace window directly so actions work while the app is in the background.
            let sel = Selector(arg)
            let window = AppDelegate.shared.workspaces.last?.window
            if let window, window.responds(to: sel) {
                NSApp.sendAction(sel, to: window, from: nil)
            } else {
                NSApp.sendAction(sel, to: NSApp.delegate, from: nil) || NSApp.sendAction(sel, to: nil, from: nil)
            }
        case "size":
            let p = arg.split(separator: "x").compactMap { Double($0) }
            if p.count == 2, let w = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
                w.setContentSize(NSSize(width: p[0], height: p[1]))
            }
        case "appearance":
            NSApp.appearance = arg == "dark" ? NSAppearance(named: .darkAqua) : (arg == "light" ? NSAppearance(named: .aqua) : nil)
        case "quit":
            NSApp.terminate(nil)
        default:
            NSLog("MTP automation: unknown command \(command)")
        }
    }

    /// Renders the frontmost window (including sheets) without needing screen-recording permission.
    private func scroll(to fraction: Double) {
        guard let root = (NSApp.keyWindow ?? NSApp.orderedWindows.first)?.contentView else { return }
        func scrollViews(_ v: NSView) -> [NSScrollView] { (v as? NSScrollView).map { [$0] } ?? [] + v.subviews.flatMap(scrollViews) }
        guard let sv = scrollViews(root).max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }),
              let doc = sv.documentView else { return }
        let range = max(0, doc.frame.height - sv.contentView.bounds.height)
        let y = doc.isFlipped ? range * fraction : range * (1 - fraction)
        sv.contentView.scroll(to: NSPoint(x: 0, y: y))
        sv.reflectScrolledClipView(sv.contentView)
    }

    private func snapshot(to path: String) {
        guard let window = NSApp.keyWindow ?? NSApp.orderedWindows.first(where: { $0.isVisible && $0.sheetParent == nil }) else { return }
        let targets = [window] + window.childWindows.orEmpty + (window.attachedSheet.map { [$0] } ?? [])
        for (i, w) in targets.enumerated() {
            guard let view = w.contentView?.superview ?? w.contentView else { continue }
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else { continue }
            let url = URL(fileURLWithPath: i == 0 ? path : path.replacingOccurrences(of: ".png", with: "-\(i).png"))
            try? data.write(to: url)
        }
    }
}

private extension Optional where Wrapped == [NSWindow] {
    var orEmpty: [NSWindow] { self ?? [] }
}
