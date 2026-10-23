import AppKit
import MTPCore

public enum CodeLanguage: Sendable {
    case sql, json, typescript, plain
}

/// Applies syntax colors to a text storage. Cheap enough to run on every edit for typical scripts.
public enum SQLHighlighter {
    public static var defaultFont: NSFont {
        let size = UserDefaults.standard.double(forKey: "editorFontSize")
        return NSFont.monospacedSystemFont(ofSize: size > 0 ? size : 13, weight: .regular)
    }

    static let tsKeywords: Set<String> = ["export", "interface", "type", "import", "from", "const", "let", "readonly", "extends",
                                          "string", "number", "boolean", "null", "undefined", "unknown", "never", "any", "Date",
                                          "Record", "Array", "true", "false", "enum", "declare", "namespace"]

    public static func highlight(_ storage: NSTextStorage, language: CodeLanguage, font: NSFont = defaultFont) {
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: NSColor.labelColor], range: full)
        if language == .plain || storage.length > 400_000 {
            storage.endEditing()
            return
        }
        let tokens = SQLTokenizer.tokenize(storage.string)
        for (i, t) in tokens.enumerated() {
            var color: NSColor?
            switch t.kind {
            case .lineComment, .blockComment: color = MTPColors.comment
            case .string, .dollarString: color = MTPColors.string
            case .number: color = MTPColors.number
            case .parameter: color = MTPColors.parameter
            case .quotedIdentifier:
                color = language == .json || language == .typescript ? MTPColors.string : MTPColors.identifier
            case .keyword:
                switch language {
                case .sql: color = MTPColors.keyword
                case .json: color = ["TRUE", "FALSE", "NULL"].contains(t.upper) ? MTPColors.keyword : nil
                case .typescript: color = tsKeywords.contains(t.text) ? MTPColors.keyword : nil
                case .plain: color = nil
                }
            case .identifier:
                if language == .typescript, tsKeywords.contains(t.text) { color = MTPColors.keyword }
                else if language == .sql, let next = tokens[(i + 1)...].first(where: { $0.kind != .whitespace }), next.kind == .openParen {
                    color = MTPColors.function
                }
            default: break
            }
            if let color { storage.addAttribute(.foregroundColor, value: color, range: t.range) }
            if t.kind == .keyword && language == .sql {
                storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask), range: t.range)
            }
        }
        storage.endEditing()
    }
}
