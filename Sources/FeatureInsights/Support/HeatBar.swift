import AppKit
import MTPCore
import MTPUIKit
import SwiftUI

/// Table cell whose right-aligned, monospaced-digit value sits on a horizontal bar (Supabase "Time consumed").
/// `fraction` sets the bar length (0…1, usually value / max row); `tone` tints it (neutral grey, orange, red).
struct HeatBarCell: View {
    var text: String
    var fraction: Double
    var tone: Tone = .neutral

    var body: some View {
        Text(text)
            .monospacedDigit()
            .lineLimit(1)
            .padding(.horizontal, DS.Space.xs + 1)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .frame(height: 16)
            .background(alignment: .leading) {
                GeometryReader { geo in
                    let f = fraction.isFinite ? min(1, max(0, fraction)) : 0
                    RoundedRectangle(cornerRadius: DS.Radius.s - 1, style: .continuous)
                        .fill(Self.fill(tone))
                        .frame(width: f > 0 ? max(3, geo.size.width * f) : 0)
                }
            }
            .accessibilityValue(text)
    }

    /// Soft fills that keep the number legible on top in light and dark mode.
    static func fill(_ tone: Tone) -> Color {
        switch tone {
        case .critical: return Color(nsColor: .systemRed).opacity(0.24)
        case .warning: return Color(nsColor: .systemOrange).opacity(0.24)
        default: return Color.primary.opacity(0.09)
        }
    }

    /// Neutral below `warning`, orange from `warning`, red from `critical` (same unit as `value`).
    static func tone(_ value: Double?, warning: Double, critical: Double) -> Tone {
        guard let value, value.isFinite else { return .neutral }
        return value >= critical ? .critical : value >= warning ? .warning : .neutral
    }
}

/// One-line SQL with the editor's syntax colours (MTPUIKit `SQLHighlighter`); plain words use the secondary label colour.
struct HighlightedSQLLine: View {
    var sql: String
    var limit = 200

    var body: some View {
        Text(Self.attributed(InsightsFormat.oneLine(sql, limit: limit)))
            .font(DS.Typo.mono)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(InsightsFormat.oneLine(sql, limit: 600))
    }

    static func attributed(_ text: String) -> AttributedString {
        let storage = NSTextStorage(string: text)
        SQLHighlighter.highlight(storage, language: .sql, font: .monospacedSystemFont(ofSize: 12, weight: .regular))
        var out = AttributedString()
        storage.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            var run = AttributedString((text as NSString).substring(with: range))
            if let color = value as? NSColor, color != NSColor.labelColor {
                run.foregroundColor = Color(nsColor: color)
            } else {
                run.foregroundColor = Color(nsColor: .secondaryLabelColor)
            }
            out.append(run)
        }
        return out
    }
}
