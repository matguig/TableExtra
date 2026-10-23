import AppKit
import SwiftUI

/// Syntax-highlighted text view for generated SQL, TypeScript, JSON, DDL...
public struct CodeView: NSViewRepresentable {
    @Binding var text: String
    var language: CodeLanguage
    var isEditable: Bool

    public init(text: Binding<String>, language: CodeLanguage = .sql, isEditable: Bool = false) {
        _text = text
        self.language = language
        self.isEditable = isEditable
    }

    /// Read-only convenience.
    public init(_ text: String, language: CodeLanguage = .sql) {
        _text = .constant(text)
        self.language = language
        self.isEditable = false
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.isRichText = false
        tv.isEditable = isEditable
        tv.isSelectable = true
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.font = SQLHighlighter.defaultFont
        tv.backgroundColor = .textBackgroundColor
        tv.delegate = context.coordinator
        tv.string = text
        SQLHighlighter.highlight(tv.textStorage!, language: language)
        scroll.hasHorizontalScroller = true
        tv.isHorizontallyResizable = true
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        return scroll
    }

    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? NSTextView else { return }
        tv.isEditable = isEditable
        if tv.string != text {
            tv.string = text
            SQLHighlighter.highlight(tv.textStorage!, language: language)
        }
    }

    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeView

        init(_ parent: CodeView) { self.parent = parent }

        public func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            let ranges = tv.selectedRanges
            SQLHighlighter.highlight(tv.textStorage!, language: parent.language)
            tv.selectedRanges = ranges
        }
    }
}
