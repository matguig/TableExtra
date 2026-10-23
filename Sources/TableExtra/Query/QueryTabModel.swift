import AppKit
import FeatureAI
import MTPCore
import MTPUIKit
import Observation

struct QueryResultItem: Identifiable {
    enum Kind {
        case rows(QueryResult)
        case command(QueryResult)
        case failure(DatabaseError)
        case explain(String)
    }

    let id = UUID()
    var index: Int
    var statement: String
    var kind: Kind

    var title: String {
        switch kind {
        case .rows(let r): return "Result \(index) · \(Fmt.count(Int64(r.rows.count)))\(r.isTruncated ? "+" : "")"
        case .command(let r): return r.commandTag.isEmpty ? "OK" : r.commandTag
        case .failure: return "Error"
        case .explain: return "Plan"
        }
    }

    var isError: Bool { if case .failure = kind { return true }; return false }
}

@MainActor
@Observable
final class QueryTabModel: WorkspaceTab, AIEditorBridge {
    let id = UUID()
    @ObservationIgnored unowned let workspace: WorkspaceModel
    var title: String
    var sql: String
    var savedSQL: String
    /// Results shown as a chart instead of a table, and their chart settings (kept while the tab lives).
    var chartResults: Set<UUID> = []
    var chartConfigs: [UUID: ChartConfig] = [:]
    var fileURL: URL?
    var selection = NSRange(location: 0, length: 0)
    var results: [QueryResultItem] = []
    var selectedResultID: UUID?
    var isRunning = false
    var runningSince: Date?
    var lastError: String?
    var inTransaction = false
    var showResults = true
    var showAI = false
    var isPreview = false
    var statusLine = ""
    @ObservationIgnored weak var textView: SQLTextView?
    @ObservationIgnored private var session: DBClient?

    init(workspace: WorkspaceModel, title: String, sql: String) {
        self.workspace = workspace
        self.title = title
        self.sql = sql
        self.savedSQL = sql
    }

    var icon: String { fileURL == nil ? "terminal" : "doc.text" }
    var hasUnsavedChanges: Bool { (fileURL != nil && sql != savedSQL) || inTransaction }

    /// Each query tab owns its connection so transactions and long queries don't block browsing.
    var client: DBClient {
        if let session { return session }
        let c = workspace.makeClient(label: "query-\(id.uuidString.prefix(4))")
        session = c
        return c
    }

    func close() {
        session?.cancel()
        session?.close()
        session = nil
    }

    func resetSession() {
        close()
        inTransaction = false
    }

    // MARK: Running

    func runCurrent() async {
        if selection.length > 0, NSMaxRange(selection) <= (sql as NSString).length {
            let text = (sql as NSString).substring(with: selection)
            let parts = StatementSplitter.split(text)
            await run(parts.isEmpty ? [SQLStatementRange(range: selection, text: text)] : parts.map {
                SQLStatementRange(range: NSRange(location: selection.location + $0.range.location, length: $0.range.length), text: $0.text)
            })
            return
        }
        guard let stmt = StatementSplitter.statement(at: selection.location, in: sql) else { return }
        await run([stmt])
    }

    func runAll() async {
        await run(StatementSplitter.split(sql))
    }

    func run(_ statements: [SQLStatementRange]) async {
        guard !statements.isEmpty, !isRunning else { return }
        let driver = workspace.connection.driver
        let writes = statements.map(\.text).filter { QueryClassifier.analyze($0, driver: driver).kind.isWrite }
        if !writes.isEmpty {
            let summary = writes.count == 1 ? "This statement modifies the database." : "\(writes.count) statements modify the database."
            guard await workspace.confirmWrite(statements: writes, summary: summary, rehearseOn: inTransaction ? nil : client) else { return }
        }
        clearErrorMarker()
        isRunning = true
        runningSince = Date()
        lastError = nil
        results = []
        let started = Date()
        var ranDDL = false
        for (i, stmt) in statements.enumerated() {
            do {
                let r = try await client.query(stmt.text, maxRows: AppSettings.queryRowLimit)
                let item = QueryResultItem(index: i + 1, statement: stmt.text, kind: r.hasRows ? .rows(r) : .command(r))
                results.append(item)
                workspace.log(sql: stmt.text, duration: r.duration, outcome: r.summary, isError: false, source: "editor")
                if QueryClassifier.analyze(stmt.text, driver: driver).kind == .ddl { ranDDL = true }
            } catch {
                let dbError = error as? DatabaseError ?? DatabaseError(error.localizedDescription)
                results.append(QueryResultItem(index: i + 1, statement: stmt.text, kind: .failure(dbError)))
                lastError = dbError.fullMessage
                workspace.log(sql: stmt.text, duration: 0, outcome: dbError.fullMessage, isError: true, source: "editor")
                markError(dbError, in: stmt)
                break
            }
        }
        inTransaction = client.inTransaction
        isRunning = false
        runningSince = nil
        let total = Date().timeIntervalSince(started)
        statusLine = lastError == nil ? "\(statements.count) statement\(statements.count == 1 ? "" : "s") · \(Fmt.duration(total))" : "Failed after \(Fmt.duration(total))"
        selectedResultID = results.last(where: { if case .rows = $0.kind { return true }; return false })?.id ?? results.last?.id
        showResults = true
        if ranDDL { workspace.refreshSidebar() }
    }

    func cancel() {
        session?.cancel()
    }

    func explainCurrent() {
        let text: String
        if selection.length > 0, NSMaxRange(selection) <= (sql as NSString).length {
            text = (sql as NSString).substring(with: selection)
        } else if let stmt = StatementSplitter.statement(at: selection.location, in: sql) {
            text = stmt.text
        } else { return }
        let item = QueryResultItem(index: results.count + 1, statement: text, kind: .explain(text))
        results.append(item)
        selectedResultID = item.id
        showResults = true
    }

    func commitTransaction() async {
        _ = try? await client.query("COMMIT")
        inTransaction = client.inTransaction
        workspace.showToast("Transaction committed")
    }

    func rollbackTransaction() async {
        _ = try? await client.query("ROLLBACK")
        inTransaction = client.inTransaction
        workspace.showToast("Transaction rolled back")
    }

    // MARK: Editor helpers

    func format() {
        let options = SQLFormatter.Options(uppercaseKeywords: UserDefaults.standard.bool(forKey: SettingKey.uppercaseCompletion),
                                           indent: String(repeating: " ", count: AppSettings.indentWidth))
        if selection.length > 0, let tv = textView {
            let text = (sql as NSString).substring(with: selection)
            tv.replace(range: selection, with: SQLFormatter.format(text, options: options), select: true)
        } else if let tv = textView {
            tv.replace(range: NSRange(location: 0, length: (sql as NSString).length), with: SQLFormatter.format(sql, options: options), select: false)
        } else {
            sql = SQLFormatter.format(sql, options: options)
        }
    }

    private func markError(_ error: DatabaseError, in stmt: SQLStatementRange) {
        guard let pos = error.position, let tv = textView, let lm = tv.layoutManager else { return }
        let ns = sql as NSString
        let statementStart = ns.range(of: stmt.text, options: [], range: NSRange(location: stmt.range.location, length: max(0, ns.length - stmt.range.location))).location
        guard statementStart != NSNotFound else { return }
        let errorAt = statementStart + max(0, pos - 1)
        guard errorAt < ns.length else { return }
        let word = ns.rangeOfCharacter(from: .whitespacesAndNewlines, options: [], range: NSRange(location: errorAt, length: ns.length - errorAt))
        let end = word.location == NSNotFound ? ns.length : word.location
        let r = NSRange(location: errorAt, length: max(1, end - errorAt))
        lm.addTemporaryAttributes([.underlineStyle: NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue,
                                   .underlineColor: NSColor.systemRed], forCharacterRange: r)
    }

    private func clearErrorMarker() {
        guard let lm = textView?.layoutManager else { return }
        let full = NSRange(location: 0, length: (sql as NSString).length)
        lm.removeTemporaryAttribute(.underlineStyle, forCharacterRange: full)
        lm.removeTemporaryAttribute(.underlineColor, forCharacterRange: full)
    }

    // MARK: Files & favorites

    func save(choosingLocation: Bool) {
        if !choosingLocation, let fileURL {
            do {
                try sql.write(to: fileURL, atomically: true, encoding: .utf8)
                savedSQL = sql
                workspace.showToast("Saved \(fileURL.lastPathComponent)")
            } catch { workspace.showError(error) }
            return
        }
        if let url = FilePanels.save(sql, suggestedName: "\(title).sql", types: [.init(filenameExtension: "sql")!]) {
            fileURL = url
            savedSQL = sql
            title = url.deletingPathExtension().lastPathComponent
        }
    }

    func saveAsFavorite() {
        let alert = NSAlert()
        alert.messageText = "Save as Favorite"
        alert.informativeText = "Favorites appear in the sidebar and in Open Anything. A keyword expands to the query in the editor."
        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 300, height: 56))
        stack.orientation = .vertical
        let name = NSTextField(string: title.hasPrefix("Query") ? "" : title)
        name.placeholderString = "Name"
        let keyword = NSTextField(string: "")
        keyword.placeholderString = "Keyword (optional), e.g. lastorders"
        let global = NSButton(checkboxWithTitle: "Available on every connection", target: nil, action: nil)
        for v in [name, keyword] { v.translatesAutoresizingMaskIntoConstraints = false; v.widthAnchor.constraint(equalToConstant: 300).isActive = true }
        stack.addArrangedSubview(name)
        stack.addArrangedSubview(keyword)
        stack.addArrangedSubview(global)
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: 80)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = name
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = selection.length > 0 ? (sql as NSString).substring(with: selection) : sql
        let q = SavedQuery(name: name.stringValue.isEmpty ? String(text.prefix(40)) : name.stringValue, sql: text,
                           keyword: keyword.stringValue.trimmingCharacters(in: .whitespaces),
                           connectionID: global.state == .on ? nil : workspace.connection.id)
        FavoritesStore.shared.upsert(q)
        workspace.showToast("Saved favorite “\(q.name)”")
    }

    // MARK: AIEditorBridge

    var editorSQL: String { sql }

    var selectedSQL: String? {
        guard selection.length > 0, NSMaxRange(selection) <= (sql as NSString).length else { return nil }
        return (sql as NSString).substring(with: selection)
    }

    func insertSQL(_ text: String, replaceAll: Bool) {
        guard let tv = textView else {
            sql = replaceAll ? text : sql + "\n" + text
            return
        }
        if replaceAll {
            tv.replace(range: NSRange(location: 0, length: (sql as NSString).length), with: text, select: false)
        } else if selection.length > 0 {
            tv.replace(range: selection, with: text, select: true)
        } else {
            let ns = sql as NSString
            let prefix = ns.length > 0 && !sql.hasSuffix("\n") ? "\n\n" : ""
            tv.replace(range: NSRange(location: ns.length, length: 0), with: prefix + text, select: true)
        }
        tv.window?.makeFirstResponder(tv)
    }
}
