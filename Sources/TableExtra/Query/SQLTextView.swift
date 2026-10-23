import AppKit
import MTPCore
import MTPUIKit

/// The query editor: highlighting, current-statement tint, line numbers, smart indent,
/// comment toggles and a custom completion popup (TablePlus `CompletionWindow`).
@MainActor
final class SQLTextView: NSTextView {
    var completionEngine: (() -> CompletionEngine)?
    var onTextChange: ((String) -> Void)?
    var onSelectionChange: ((NSRange) -> Void)?
    var indentWidth = 2
    private var highlightWork: DispatchWorkItem?
    private var completionWork: DispatchWorkItem?
    private(set) var currentStatementRange: NSRange?
    private lazy var popup = CompletionPopup(textView: self)

    static func make() -> (NSScrollView, SQLTextView) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let tv = SQLTextView(frame: .zero, textContainer: container)
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.textContainerInset = NSSize(width: 4, height: 6)
        tv.font = SQLHighlighter.defaultFont
        tv.backgroundColor = .textBackgroundColor
        tv.insertionPointColor = .controlAccentColor
        tv.typingAttributes = [.font: SQLHighlighter.defaultFont, .foregroundColor: NSColor.labelColor]

        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        let ruler = LineNumberRulerView(textView: tv)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: tv, queue: .main) { _ in
            MainActor.assumeIsolated {
                tv.textChanged()
                ruler.needsDisplay = true
            }
        }
        NotificationCenter.default.addObserver(forName: NSTextView.didChangeSelectionNotification, object: tv, queue: .main) { _ in
            MainActor.assumeIsolated {
                tv.selectionChanged()
                ruler.needsDisplay = true
            }
        }
        NotificationCenter.default.addObserver(forName: .mtpFontSizeChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                tv.font = SQLHighlighter.defaultFont
                tv.rehighlight()
                ruler.needsDisplay = true
            }
        }
        return (scroll, tv)
    }

    func setText(_ text: String) {
        guard string != text else { return }
        string = text
        rehighlight()
    }

    // MARK: Highlighting

    func rehighlight() {
        let ranges = selectedRanges
        SQLHighlighter.highlight(textStorage!, language: .sql, font: SQLHighlighter.defaultFont)
        typingAttributes = [.font: SQLHighlighter.defaultFont, .foregroundColor: NSColor.labelColor]
        selectedRanges = ranges
        updateCurrentStatement()
    }

    fileprivate func textChanged() {
        onTextChange?(string)
        highlightWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rehighlight() }
        highlightWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (string.utf16.count > 20_000 ? 0.25 : 0.03), execute: work)
    }

    fileprivate func selectionChanged() {
        onSelectionChange?(selectedRange())
        updateCurrentStatement()
        if popup.isVisible, !popupStillValid() { popup.hide() }
    }

    /// Soft background behind the statement ⌘↩ would run.
    func updateCurrentStatement() {
        guard let lm = layoutManager else { return }
        let full = NSRange(location: 0, length: (string as NSString).length)
        lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
        guard selectedRange().length == 0, let stmt = StatementSplitter.statement(at: selectedRange().location, in: string),
              StatementSplitter.split(string).count > 1 else {
            currentStatementRange = nil
            return
        }
        currentStatementRange = stmt.range
        lm.addTemporaryAttribute(.backgroundColor, value: NSColor.controlAccentColor.withAlphaComponent(0.07), forCharacterRange: stmt.range)
    }

    // MARK: Editing helpers

    override func insertNewline(_ sender: Any?) {
        if popup.isVisible { popup.accept(); return }
        let ns = string as NSString
        let caret = selectedRange().location
        let lineRange = ns.lineRange(for: NSRange(location: caret, length: 0))
        let line = ns.substring(with: NSRange(location: lineRange.location, length: caret - lineRange.location))
        var indent = String(line.prefix { $0 == " " || $0 == "\t" })
        let trimmed = line.trimmingCharacters(in: .whitespaces).uppercased()
        if trimmed.hasSuffix("(") || trimmed.hasSuffix("SELECT") || trimmed.hasSuffix("BEGIN") {
            indent += String(repeating: " ", count: indentWidth)
        }
        insertText("\n" + indent, replacementRange: selectedRange())
    }

    override func insertTab(_ sender: Any?) {
        if popup.isVisible { popup.accept(); return }
        if selectedRange().length > 0 { shiftLines(by: 1); return }
        insertText(String(repeating: " ", count: indentWidth), replacementRange: selectedRange())
    }

    override func insertBacktab(_ sender: Any?) { shiftLines(by: -1) }

    func shiftLines(by direction: Int) {
        let ns = string as NSString
        let lines = ns.lineRange(for: selectedRange())
        let text = ns.substring(with: lines)
        let pad = String(repeating: " ", count: indentWidth)
        let out = text.components(separatedBy: "\n").enumerated().map { i, l -> String in
            if l.isEmpty && i > 0 { return l }
            if direction > 0 { return pad + l }
            var s = Substring(l)
            var n = 0
            while n < indentWidth, s.first == " " { s = s.dropFirst(); n += 1 }
            return String(s)
        }.joined(separator: "\n")
        replace(range: lines, with: out, select: true)
    }

    func toggleLineComment() {
        let ns = string as NSString
        let lines = ns.lineRange(for: selectedRange())
        let parts = ns.substring(with: lines).components(separatedBy: "\n")
        let content = parts.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let allCommented = !content.isEmpty && content.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix("--") }
        let out = parts.map { l -> String in
            if l.trimmingCharacters(in: .whitespaces).isEmpty { return l }
            if allCommented {
                guard let r = l.range(of: "--") else { return l }
                var rest = l[r.upperBound...]
                if rest.first == " " { rest = rest.dropFirst() }
                return String(l[..<r.lowerBound]) + rest
            }
            let indent = l.prefix { $0 == " " || $0 == "\t" }
            return indent + "-- " + l.dropFirst(indent.count)
        }.joined(separator: "\n")
        replace(range: lines, with: out, select: selectedRange().length > 0)
    }

    func toggleBlockComment() {
        let r = selectedRange()
        let ns = string as NSString
        let target = r.length > 0 ? r : (currentStatementRange ?? r)
        let s = ns.substring(with: target)
        if s.hasPrefix("/*") && s.hasSuffix("*/") {
            replace(range: target, with: String(s.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces), select: true)
        } else {
            replace(range: target, with: "/* " + s + " */", select: true)
        }
    }

    func replace(range: NSRange, with text: String, select: Bool) {
        guard shouldChangeText(in: range, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
        setSelectedRange(select ? NSRange(location: range.location, length: (text as NSString).length)
                                : NSRange(location: range.location + (text as NSString).length, length: 0))
    }

    /// Wraps typed quotes/brackets around a selection.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        if let s = string as? String, s.count == 1, selectedRange().length > 0,
           let close = ["(": ")", "'": "'", "\"": "\"", "[": "]", "`": "`"][s] {
            let sel = (self.string as NSString).substring(with: selectedRange())
            replace(range: selectedRange(), with: s + sel + close, select: false)
            return
        }
        super.insertText(string, replacementRange: replacementRange)
        if let s = string as? String, s.count == 1 { scheduleCompletion(trigger: s) }
    }

    // MARK: Completion

    private var autoCompletion: Bool { UserDefaults.standard.bool(forKey: SettingKey.autoCompletion) }

    private func scheduleCompletion(trigger: String) {
        completionWork?.cancel()
        guard autoCompletion else { return }
        let c = trigger.unicodeScalars.first!
        let isWordChar = CharacterSet.alphanumerics.contains(c) || trigger == "_"
        guard isWordChar || trigger == "." else {
            popup.hide()
            return
        }
        if popup.isVisible {
            showCompletions(explicit: false)
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.showCompletions(explicit: false) }
        completionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    override func complete(_ sender: Any?) { showCompletions(explicit: true) }

    /// Identifier fragment before the caret, the qualifier before a dot, and the keyword before that.
    func completionContext() -> (range: NSRange, prefix: String, qualifier: String?, previous: String?, statement: String)? {
        let caret = selectedRange().location
        guard selectedRange().length == 0 else { return nil }
        let ns = string as NSString
        let tokens = SQLTokenizer.tokenize(string)
        // Never complete inside strings or comments.
        if let inside = tokens.first(where: { $0.location < caret && caret < $0.end }), [.string, .dollarString, .lineComment, .blockComment].contains(inside.kind) {
            return nil
        }
        var start = caret
        while start > 0 {
            let ch = ns.character(at: start - 1)
            guard let scalar = UnicodeScalar(ch), CharacterSet.alphanumerics.contains(scalar) || ch == 95 || ch == 36 else { break }
            start -= 1
        }
        let prefix = ns.substring(with: NSRange(location: start, length: caret - start))
        var qualifier: String?
        if start > 0, ns.character(at: start - 1) == 46 {
            var q = start - 1
            while q > 0 {
                let ch = ns.character(at: q - 1)
                guard let scalar = UnicodeScalar(ch), CharacterSet.alphanumerics.contains(scalar) || ch == 95 || ch == 34 else { break }
                q -= 1
            }
            qualifier = ns.substring(with: NSRange(location: q, length: start - 1 - q))
        }
        let before = tokens.filter { $0.end <= start - (qualifier == nil ? 0 : (qualifier!.utf16.count + 1)) && !$0.kind.isTrivia }
        let previous = before.last.flatMap { $0.kind == .keyword || $0.kind == .identifier ? $0.upper : ($0.kind == .comma ? "," : nil) }
        let stmt = StatementSplitter.statement(at: caret, in: string)?.text ?? string
        return (NSRange(location: start, length: caret - start), prefix, qualifier, previous, stmt)
    }

    private func showCompletions(explicit: Bool) {
        guard let engine = completionEngine?(), let ctx = completionContext() else { popup.hide(); return }
        if !explicit, ctx.qualifier == nil, ctx.prefix.count < 1 { popup.hide(); return }
        // After a comma in a FROM list, keep suggesting tables.
        var previous = ctx.previous
        if previous == "," {
            let aliases = CompletionEngine.aliases(in: ctx.statement)
            previous = aliases.isEmpty ? nil : "FROM"
        }
        let items = engine.suggestions(statement: ctx.statement, prefix: ctx.prefix, qualifier: ctx.qualifier, previousWord: previous)
        let filtered = items.filter { $0.text.caseInsensitiveCompare(ctx.prefix) != .orderedSame || explicit }
        guard !filtered.isEmpty else { popup.hide(); return }
        popup.show(items: Array(filtered.prefix(80)), replacing: ctx.range)
    }

    private func popupStillValid() -> Bool {
        guard let ctx = completionContext() else { return false }
        return ctx.range.location == popup.replaceRange.location
    }

    func insertCompletion(_ item: CompletionItem, replacing range: NSRange) {
        let text = item.insertion ?? item.text
        let ns = string as NSString
        let current = NSRange(location: range.location, length: max(0, selectedRange().location - range.location))
        guard NSMaxRange(current) <= ns.length else { return }
        replace(range: current, with: text, select: false)
        popup.hide()
    }

    override func keyDown(with event: NSEvent) {
        if popup.isVisible, popup.handle(event) { return }
        if event.keyCode == 49, event.modifierFlags.contains(.control) { // ⌃Space
            showCompletions(explicit: true)
            return
        }
        super.keyDown(with: event)
    }

    override func resignFirstResponder() -> Bool {
        popup.hide()
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { popup.hide() }
        super.viewWillMove(toWindow: newWindow)
    }
}

/// Floating list of completions anchored under the caret.
@MainActor
final class CompletionPopup: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private weak var textView: SQLTextView?
    private let panel: NSPanel
    private let table = NSTableView()
    private var items: [CompletionItem] = []
    private(set) var replaceRange = NSRange(location: 0, length: 0)

    init(textView: SQLTextView) {
        self.textView = textView
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 220), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        super.init()
        panel.isFloatingPanel = true
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 8
        effect.layer?.masksToBounds = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        table.backgroundColor = .clear
        table.headerView = nil
        table.rowHeight = 20
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.style = .plain
        table.addTableColumn(NSTableColumn(identifier: .init("c")))
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        effect.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: effect.topAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -4),
        ])
        panel.contentView = effect
    }

    var isVisible: Bool { panel.isVisible }

    func show(items: [CompletionItem], replacing range: NSRange) {
        guard let tv = textView, let window = tv.window, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        self.items = items
        replaceRange = range
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        table.scrollRowToVisible(0)
        let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: range.location, length: 0), actualCharacterRange: nil)
        var rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
        rect.origin.x += tv.textContainerOrigin.x
        rect.origin.y += tv.textContainerOrigin.y
        let inWindow = tv.convert(rect, to: nil)
        let onScreen = window.convertToScreen(inWindow)
        let height = min(CGFloat(items.count) * 20 + 8, 240)
        panel.setFrame(NSRect(x: onScreen.minX - 24, y: onScreen.minY - height - 2, width: 380, height: height), display: true)
        if !panel.isVisible { window.addChildWindow(panel, ordered: .above) }
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    func accept() {
        let row = table.selectedRow
        guard row >= 0, row < items.count, let tv = textView else { hide(); return }
        tv.insertCompletion(items[row], replacing: replaceRange)
    }

    @objc private func doubleClicked() { accept() }

    /// Returns true when the key was consumed by the popup.
    func handle(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 125: move(1); return true
        case 126: move(-1); return true
        case 121: move(8); return true
        case 116: move(-8); return true
        case 53: hide(); return true
        case 36, 76, 48: accept(); return true
        default: return false
        }
    }

    private func move(_ d: Int) {
        guard !items.isEmpty else { return }
        let r = max(0, min(items.count - 1, table.selectedRow + d))
        table.selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false)
        table.scrollRowToVisible(r)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let id = NSUserInterfaceItemIdentifier("completion")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? CompletionCell ?? CompletionCell(identifier: id)
        cell.configure(item)
        return cell
    }
}

private final class CompletionCell: NSTableCellView {
    let badge = NSTextField(labelWithString: "")
    let title = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        for f in [badge, title, detail] {
            f.translatesAutoresizingMaskIntoConstraints = false
            f.lineBreakMode = .byTruncatingTail
            addSubview(f)
        }
        badge.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 3
        title.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        detail.font = NSFont.systemFont(ofSize: 10)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .right
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 6),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ item: CompletionItem) {
        badge.stringValue = item.kind.symbol
        let colors: [CompletionItem.Kind: NSColor] = [.keyword: MTPColors.keyword, .table: .systemBlue, .view: .systemTeal, .column: .systemGreen,
                                                      .function: .systemOrange, .schema: .systemPurple, .snippet: .systemYellow]
        badge.textColor = colors[item.kind] ?? .labelColor
        title.stringValue = item.text
        detail.stringValue = item.detail
    }
}

/// Gutter with line numbers; the current line is emphasised.
final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 40
    }

    required init(coder: NSCoder) { fatalError() }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        let ns = tv.string as NSString
        let visible = tv.visibleRect
        let glyphRange = lm.glyphRange(forBoundingRect: visible, in: tc)
        let charRange = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let font = NSFont.monospacedDigitSystemFont(ofSize: max(9, (tv.font?.pointSize ?? 13) - 2), weight: .regular)
        let caretLine = ns.lineRange(for: NSRange(location: min(tv.selectedRange().location, ns.length), length: 0)).location

        var lineNumber = 1
        var idx = 0
        // Count lines before the visible range.
        while idx < charRange.location {
            let lr = ns.lineRange(for: NSRange(location: idx, length: 0))
            idx = NSMaxRange(lr)
            lineNumber += 1
        }
        if charRange.location == 0 { lineNumber = 1; idx = 0 }
        let width = max(32, CGFloat(String(max(lineNumber + 200, 999)).count) * font.pointSize * 0.62 + 14)
        if abs(ruleThickness - width) > 1 { ruleThickness = width }
        let yOffset = convert(NSPoint.zero, from: tv).y

        func drawNumber(_ n: Int, lineStart: Int, rectY: CGFloat, height: CGFloat) {
            let isCurrent = lineStart == caretLine
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: isCurrent ? NSColor.labelColor : NSColor.tertiaryLabelColor]
            let s = NSAttributedString(string: "\(n)", attributes: attrs)
            let size = s.size()
            s.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: rectY + yOffset + (height - size.height) / 2 + tv.textContainerInset.height))
        }

        while idx <= NSMaxRange(charRange) && idx <= ns.length {
            let lr = ns.lineRange(for: NSRange(location: idx, length: 0))
            let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: lr.location, length: max(lr.length, 0)), actualCharacterRange: nil)
            let r = lm.lineFragmentRect(forGlyphAt: min(glyphs.location, max(0, lm.numberOfGlyphs - 1)), effectiveRange: nil)
            if lm.numberOfGlyphs == 0 {
                drawNumber(1, lineStart: 0, rectY: 0, height: tv.font?.boundingRectForFont.height ?? 16)
                break
            }
            drawNumber(lineNumber, lineStart: lr.location, rectY: r.minY, height: r.height)
            if NSMaxRange(lr) == idx { break }
            idx = NSMaxRange(lr)
            lineNumber += 1
            if idx == ns.length {
                if ns.length > 0, ns.character(at: ns.length - 1) == 10 {
                    let extra = lm.extraLineFragmentRect
                    drawNumber(lineNumber, lineStart: ns.length, rectY: extra.minY, height: extra.height)
                }
                break
            }
        }
    }
}
