import AppKit
import MTPCore
import MTPUIKit
import SwiftUI

enum Tone {
    case neutral, good, warning, critical, info

    var color: Color {
        switch self {
        case .neutral: return .secondary
        case .good: return .green
        case .warning: return .orange
        case .critical: return .red
        case .info: return .accentColor
        }
    }

    var nsColor: NSColor {
        switch self {
        case .neutral: return .systemGray
        case .good: return .systemGreen
        case .warning: return .systemOrange
        case .critical: return .systemRed
        case .info: return .controlAccentColor
        }
    }
}

enum InsightsFormat {
    static func percent(_ fraction: Double?, digits: Int = 1) -> String {
        guard let fraction, fraction.isFinite else { return "—" }
        return String(format: "%.\(digits)f%%", fraction * 100)
    }

    /// "3h 05m", "12 d"…
    static func duration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite else { return "—" }
        let s = max(0, seconds)
        if s < 60 { return s < 10 ? String(format: "%.1f s", s) : String(format: "%.0f s", s) }
        if s < 86_400 { return Fmt.duration(s) }
        let days = Int(s) / 86_400
        let hours = (Int(s) % 86_400) / 3600
        return days < 10 ? "\(days)d \(hours)h" : "\(days) days"
    }

    /// "3h ago" or "never" for an age in seconds.
    static func ago(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite else { return "never" }
        return duration(seconds) + " ago"
    }

    static func ms(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        if value < 1 { return String(format: "%.3f ms", value) }
        if value < 100 { return String(format: "%.2f ms", value) }
        if value < 10_000 { return String(format: "%.0f ms", value) }
        return Fmt.duration(value / 1000)
    }

    static func count(_ value: Int64?) -> String { Fmt.count(value) }

    static func count(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        if abs(value) >= 9.2e18 { return String(format: "%.3g", value) }
        if value != value.rounded() && abs(value) < 100 { return String(format: "%.1f", value) }
        return Fmt.count(Int64(value.rounded()))
    }

    static func compact(_ value: Double?) -> String {
        guard let value, value.isFinite, abs(value) < 9.2e18 else { return "—" }
        return Fmt.compact(Int64(value.rounded()))
    }

    static func bytes(_ value: Int64?) -> String { Fmt.bytes(value) }

    static func cost(_ value: Double) -> String {
        value >= 100_000 ? Fmt.compact(Int64(value)) : String(format: "%.2f", value)
    }

    /// Single line, whitespace squeezed, capped.
    static func oneLine(_ text: String?, limit: Int = 160) -> String {
        guard let text else { return "" }
        let s = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return s.count > limit ? String(s.prefix(limit)) + "…" : s
    }
}

/// One dashboard section: uppercase `SectionLabel` (count / severity tag, spinner, accessory) above a `Card`.
/// `plain` drops the card so the content (e.g. the stat tile grid) sits directly on the canvas.
struct InsightsCard<Accessory: View, Content: View>: View {
    var title: String
    var systemImage: String
    var subtitle: String?
    var badge: String?
    var badgeTone: Tone = .neutral
    var isLoading = false
    var plain = false
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionLabel(title, count: neutralCount) {
                HStack(spacing: DS.Space.m) {
                    if let badge, neutralCount == nil { Tag(badge, tone: badgeTone) }
                    if isLoading { ProgressView().controlSize(.mini) }
                    accessory()
                }
            }
            .frame(minHeight: 22)
            .padding(.horizontal, DS.Space.xs)
            if plain {
                sectionBody
            } else {
                Card(padding: DS.Space.l) { sectionBody }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Plain counts ("6 tables", "0 locks") read as a quiet number; findings get a tinted tag.
    private var neutralCount: Int? {
        guard let badge, let n = Int(badge) else { return nil }
        return badgeTone == .neutral || n == 0 ? n : nil
    }

    private var sectionBody: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            if let subtitle {
                Text(subtitle)
                    .font(DS.Typo.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension InsightsCard where Accessory == EmptyView {
    init(title: String, systemImage: String, subtitle: String? = nil, badge: String? = nil, badgeTone: Tone = .neutral,
         isLoading: Bool = false, plain: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, systemImage: systemImage, subtitle: subtitle, badge: badge, badgeTone: badgeTone,
                  isLoading: isLoading, plain: plain, accessory: { EmptyView() }, content: content)
    }
}

extension Tag {
    /// Severity / count tag in this module's tone vocabulary.
    init(_ text: String, tone: Tone, uppercase: Bool = true) {
        self.init(uppercase ? text.uppercased() : text, color: tone.nsColor)
    }
}

/// Metric tile for the overview grids. Fixed height so every tile in a row lines up, whatever its content.
struct StatTile: View {
    var title: String
    var value: String
    var detail: String?
    var systemImage: String
    var tone: Tone = .neutral
    /// 0…1 meter pinned to the bottom of the tile.
    var progress: Double?

    static let height: CGFloat = 96
    static let columns = [GridItem(.adaptive(minimum: 220), spacing: DS.Space.m, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 10, weight: .medium)).frame(width: 12)
                Text(title.uppercased()).font(DS.Typo.eyebrow).tracking(0.5)
                Spacer(minLength: 0)
                if tone == .warning || tone == .critical {
                    Circle().fill(Color(nsColor: tone.nsColor)).frame(width: 6, height: 6)
                }
            }
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(height: 14)
            Text(value)
                .font(.system(size: 17, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(tone == .warning || tone == .critical ? Color(nsColor: tone.nsColor.readableText()) : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.top, DS.Space.s)
            if let detail {
                Text(detail)
                    .font(DS.Typo.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .padding(.top, DS.Space.xxs)
                    .help(detail)
            }
            Spacer(minLength: 0)
            if let progress {
                Meter(fraction: progress, tone: tone).frame(height: 3)
            }
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.m + 2)
        .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous).fill(DS.Palette.surface))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
                .strokeBorder(tone == .warning || tone == .critical ? Color(nsColor: tone.nsColor).opacity(0.45) : DS.Palette.separator.opacity(0.7),
                              lineWidth: 0.5)
        )
    }
}

/// Thin proportion bar. Neutral (grey) unless the value carries a status.
struct Meter: View {
    var fraction: Double
    var tone: Tone = .neutral

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(Color(nsColor: tone.nsColor))
                    .frame(width: max(fraction > 0 ? 2 : 0, geo.size.width * min(1, max(0, fraction))))
            }
        }
    }
}

/// "Open in Query Tab" for a suggested fix. Never runs the SQL.
struct FixButton: View {
    var title: String
    var label: String = "Open in Query Tab"
    var sql: String
    var open: (String, String) -> Void

    var body: some View {
        Button {
            open(title, sql)
        } label: {
            Label(label, systemImage: "arrow.up.forward.square").lineLimit(1).fixedSize()
        }
        .controlSize(.small)
        .help(sql)
    }
}

struct EmptyFinding: View {
    var text: String
    var systemImage = "checkmark.circle.fill"
    var tone: Tone = .good

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: systemImage).foregroundStyle(tone == .neutral ? Color.secondary : Color(nsColor: tone.nsColor))
            Text(text).foregroundStyle(.secondary)
        }
        .font(DS.Typo.callout)
    }
}

/// Section-level error as a `Banner`; permission errors add the pg_monitor hint and fix.
struct SectionErrorView: View {
    var message: String
    var isPermission = false
    var user: String = ""
    var open: ((String, String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Banner(isPermission ? .warning : .error, message)
            if isPermission {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.m) {
                    Text("This role cannot read these statistics. On RDS, an admin can grant the built-in pg_monitor role (it includes pg_read_all_stats).")
                        .font(DS.Typo.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if let open {
                        let role = user.isEmpty ? "CURRENT_USER" : SQLDialect(kind: .postgres).quoteIdentIfNeeded(user)
                        FixButton(title: "Grant pg_monitor", sql: "GRANT pg_monitor TO \(role);", open: open)
                    }
                }
                .padding(.horizontal, DS.Space.xs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Toggle rendered as a toolbar chip: icon + label, tinted when on. Collapses to the icon inside a compact `ToolStrip`.
struct ToggleChip: View {
    var title: String
    var systemImage: String
    @Binding var isOn: Bool
    var help: String?
    @Environment(\.toolStripCompact) private var compact
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 11, weight: .medium)).frame(width: 14)
                if !compact { Text(title).lineLimit(1).fixedSize() }
            }
            .font(.system(size: 12, weight: isOn ? .medium : .regular))
            .foregroundStyle(foreground)
            .padding(.horizontal, compact ? 6 : 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).fill(background))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help((help ?? title) + (isOn ? " (on)" : " (off)"))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var foreground: Color {
        if !enabled { return Color(nsColor: .tertiaryLabelColor) }
        return isOn ? Color(nsColor: NSColor.controlAccentColor.readableText()) : .primary.opacity(0.75)
    }

    private var background: Color {
        if isOn { return Color(nsColor: NSColor.controlAccentColor.softFill()) }
        return hover && enabled ? DS.Palette.hover : .clear
    }
}

/// Monospaced, selectable, single-or-multi-line SQL snippet.
struct SQLSnippet: View {
    var text: String
    var lineLimit: Int? = 3

    var body: some View {
        Text(text)
            .font(DS.Typo.monoSmall)
            .foregroundStyle(.secondary)
            .lineLimit(lineLimit)
            .truncationMode(.tail)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Row container used by finding lists (alternating background, padding).
struct FindingRow<Content: View>: View {
    var index: Int
    var highlight: Tone?
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, DS.Space.m + 2)
            .padding(.vertical, DS.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                    .fill(highlight.map { Color(nsColor: $0.nsColor).opacity(0.08) } ?? (index.isMultiple(of: 2) ? Color.primary.opacity(0.035) : Color.clear))
            )
    }
}

/// Section body that shows loading / error / content for a SectionState.
struct SectionBody<Value, Content: View>: View {
    var state: SectionState<Value>
    var user: String = ""
    var open: ((String, String) -> Void)?
    @ViewBuilder var content: (Value) -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            if let error = state.error {
                SectionErrorView(message: error, isPermission: state.isPermissionError, user: user, open: open)
            }
            if let value = state.value {
                content(value)
            } else if state.error == nil {
                HStack(spacing: DS.Space.s) {
                    ProgressView().controlSize(.small)
                    Text("Loading…").foregroundStyle(.secondary)
                }
                .font(DS.Typo.callout)
                .padding(.vertical, DS.Space.xs)
            }
        }
    }
}
