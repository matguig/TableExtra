import AppKit
import LocalAuthentication
import MTPCore
import MTPUIKit

/// Decides whether a write may reach the server, per the connection's safety settings.
/// Superset of TablePlus Silent / Warning / Safe modes, plus dry-run counts and a WHERE guard.
@MainActor
enum SafetyGate {
    struct Request {
        var statements: [String]
        var summary: String
        /// Rows affected when the write was rehearsed inside BEGIN … ROLLBACK (nil = not rehearsed).
        var dryRunRows: Int?
        var dryRunError: String?
    }

    static func needsConfirmation(_ statements: [String], config: ConnectionConfig) -> Bool {
        let analyses = statements.map { QueryClassifier.analyze($0, driver: config.driver) }
        guard analyses.contains(where: { $0.kind.isWrite }) else { return false }
        if config.safety != .silent { return true }
        if config.guardUnboundedWrites && analyses.contains(where: { $0.isUnbounded }) { return true }
        return config.isProductionLike && analyses.contains(where: { $0.isDestructive })
    }

    /// Returns true when the user allowed the write.
    static func confirm(_ request: Request, config: ConnectionConfig, window: NSWindow?) async -> Bool {
        let analyses = request.statements.map { QueryClassifier.analyze($0, driver: config.driver) }
        if config.safety == .readOnly {
            await show(alert: makeAlert(
                title: "\(config.name) is read-only",
                text: "Writes are blocked on this connection. Change its safety level in Connection → Safety Level to allow them.",
                buttons: ["OK"], style: .informational), window: window)
            return false
        }

        let unbounded = analyses.filter(\.isUnbounded)
        let destructive = analyses.filter(\.isDestructive)
        var text = request.summary
        if let n = request.dryRunRows {
            text += "\n\nDry run (rolled back): \(Fmt.count(Int64(n))) row\(n == 1 ? "" : "s") would be affected."
        } else if let e = request.dryRunError {
            text += "\n\nDry run failed: \(e)"
        }
        let warnings = Array(Set(analyses.flatMap(\.warnings))).sorted()
        if !warnings.isEmpty { text += "\n\n⚠︎ " + warnings.joined(separator: "\n⚠︎ ") }
        let preview = request.statements.prefix(5).map { $0.count > 600 ? String($0.prefix(600)) + "…" : $0 }.joined(separator: ";\n\n")

        // Typing the table/database name is required for unbounded or destructive writes on prod-like servers.
        let mustType = config.isProductionLike && (!unbounded.isEmpty || !destructive.isEmpty)
        let typeTarget = (unbounded.first?.targetTable ?? destructive.first?.targetTable ?? config.database)
            .replacingOccurrences(of: "\"", with: "")

        let alert = makeAlert(
            title: config.isProductionLike ? "Run on \(config.environment.displayName.uppercased()) — \(config.name)?" : "Run write on \(config.name)?",
            text: text,
            buttons: [unbounded.isEmpty ? "Execute" : "Execute on every row", "Cancel"],
            style: config.isProductionLike || !destructive.isEmpty ? .critical : .warning)
        let accessory = NSStackView()
        accessory.orientation = .vertical
        accessory.alignment = .leading
        let sqlView = NSTextView(frame: NSRect(x: 0, y: 0, width: 440, height: 120))
        sqlView.string = preview
        sqlView.isEditable = false
        sqlView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        SQLHighlighter.highlight(sqlView.textStorage!, language: .sql, font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: 120))
        scroll.documentView = sqlView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 440).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 120).isActive = true
        accessory.addArrangedSubview(scroll)
        var field: NSTextField?
        if mustType {
            let label = NSTextField(labelWithString: "Type \(typeTarget) to confirm:")
            let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 440, height: 24))
            f.placeholderString = typeTarget
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(equalToConstant: 440).isActive = true
            accessory.addArrangedSubview(label)
            accessory.addArrangedSubview(f)
            field = f
        }
        accessory.frame = NSRect(x: 0, y: 0, width: 440, height: mustType ? 176 : 124)
        alert.accessoryView = accessory
        if let field { alert.window.initialFirstResponder = field }
        let response = await show(alert: alert, window: window)
        guard response == .alertFirstButtonReturn else { return false }
        if let field, field.stringValue.trimmingCharacters(in: .whitespaces) != typeTarget {
            await show(alert: makeAlert(title: "Confirmation text did not match", text: "Nothing was executed.", buttons: ["OK"], style: .informational), window: window)
            return false
        }
        if config.safety == .protectedWrites {
            return await authenticate(reason: "run a write on \(config.name)")
        }
        return true
    }

    static func authenticate(reason: String) async -> Bool {
        let ctx = LAContext()
        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        do {
            return try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }

    private static func makeAlert(title: String, text: String, buttons: [String], style: NSAlert.Style) -> NSAlert {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.alertStyle = style
        for b in buttons { a.addButton(withTitle: b) }
        if buttons.count > 1 { a.buttons[1].keyEquivalent = "\u{1b}" }
        return a
    }

    @discardableResult
    private static func show(alert: NSAlert, window: NSWindow?) async -> NSApplication.ModalResponse {
        guard let window, window.isVisible else { return alert.runModal() }
        return await withCheckedContinuation { cont in
            alert.beginSheetModal(for: window) { cont.resume(returning: $0) }
        }
    }
}
