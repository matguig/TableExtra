import AppKit
import MTPCore
import SwiftUI

/// Spacing, radii and type scale shared by every screen. Use these instead of literals.
public enum DS {
    public enum Space {
        public static let xxs: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 6
        public static let m: CGFloat = 8
        public static let l: CGFloat = 12
        public static let xl: CGFloat = 16
        public static let xxl: CGFloat = 24
    }

    public enum Radius {
        public static let s: CGFloat = 4
        public static let m: CGFloat = 6
        public static let l: CGFloat = 10
        public static let xl: CGFloat = 14
    }

    public enum Metrics {
        /// Height of pane headers and the tab-level toolbar strip.
        public static let toolbarHeight: CGFloat = 38
        /// Height of the bottom status strip.
        public static let statusBarHeight: CGFloat = 26
        public static let tabBarHeight: CGFloat = 32
        public static let sidebarWidth: CGFloat = 240
        public static let rowHeight: CGFloat = 24
    }

    public enum Typo {
        public static let title = Font.system(size: 15, weight: .semibold)
        public static let headline = Font.system(size: 13, weight: .semibold)
        public static let body = Font.system(size: 13)
        public static let callout = Font.system(size: 12)
        public static let caption = Font.system(size: 11)
        public static let micro = Font.system(size: 10, weight: .medium)
        public static let mono = Font.system(size: 12, design: .monospaced)
        public static let monoSmall = Font.system(size: 11, design: .monospaced)
        /// Uppercase section labels ("TABLES", "OVERVIEW").
        public static let eyebrow = Font.system(size: 10, weight: .semibold)
    }

    public enum Palette {
        public static let separator = Color(nsColor: .separatorColor)
        /// Raised surface for cards and grouped content.
        public static let surface = Color(nsColor: NSColor(name: nil) { a in
            a.isDark ? NSColor(white: 1, alpha: 0.045) : NSColor.white
        })
        /// Recessed background behind cards (dashboards, diagram canvas).
        public static let canvas = Color(nsColor: NSColor(name: nil) { a in
            a.isDark ? NSColor(white: 0.10, alpha: 1) : NSColor(srgbRed: 0.965, green: 0.965, blue: 0.972, alpha: 1)
        })
        /// Bars (pane headers, status bar) — flat, slightly off the content background.
        public static let bar = Color(nsColor: NSColor(name: nil) { a in
            a.isDark ? NSColor(white: 0.16, alpha: 1) : NSColor(srgbRed: 0.975, green: 0.975, blue: 0.98, alpha: 1)
        })
        public static let hover = Color.primary.opacity(0.06)
        public static let pressed = Color.primary.opacity(0.10)
    }
}

public extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight]).map { $0 == .darkAqua || $0 == .vibrantDark } ?? false }
}

public extension NSColor {
    /// The same hue made legible as text: darker in light mode, lighter in dark mode.
    func readableText() -> NSColor {
        NSColor(name: nil) { [self] a in
            a.isDark ? (self.blended(withFraction: 0.25, of: .white) ?? self) : (self.blended(withFraction: 0.42, of: .black) ?? self)
        }
    }

    /// A soft fill of this hue for tags and highlighted rows.
    func softFill() -> NSColor {
        NSColor(name: nil) { [self] a in self.withAlphaComponent(a.isDark ? 0.24 : 0.14) }
    }
}

public extension Color {
    init(hex: String, fallback: Color) { self = Color(hex: hex) ?? fallback }
}

// MARK: - Tags

/// Small rounded label. `.soft` = tinted fill + readable text; `.solid` = filled, for high-risk states.
public struct Tag: View {
    public enum Style { case soft, solid, outline }
    var text: String
    var color: NSColor
    var style: Style
    var systemImage: String?

    public init(_ text: String, color: NSColor, style: Style = .soft, systemImage: String? = nil) {
        self.text = text
        self.color = color
        self.style = style
        self.systemImage = systemImage
    }

    public var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 8, weight: .bold)) }
            Text(text)
        }
        .font(.system(size: 9.5, weight: .semibold))
        .tracking(0.4)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 6)
        .frame(height: 16)
        .foregroundStyle(foreground)
        .background(RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous).fill(fill))
        .overlay {
            if style == .outline {
                RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous).strokeBorder(Color(nsColor: color).opacity(0.6), lineWidth: 0.75)
            }
        }
    }

    private var foreground: Color {
        switch style {
        case .solid: return Color(nsColor: color.contrastingText)
        case .soft, .outline: return Color(nsColor: color.readableText())
        }
    }

    private var fill: Color {
        switch style {
        case .solid: return Color(nsColor: color)
        case .soft: return Color(nsColor: color.softFill())
        case .outline: return .clear
        }
    }
}

/// Environment label (LOCAL, DEVELOPMENT, STAGING, PRODUCTION). Production is solid so it is never missed.
public struct EnvironmentTag: View {
    var environment: ConnectionEnvironment
    var colorHex: String?
    var compact: Bool

    public init(environment: ConnectionEnvironment, colorHex: String? = nil, compact: Bool = false) {
        self.environment = environment
        self.colorHex = colorHex
        self.compact = compact
    }

    public var body: some View {
        // The environment's own color, not the connection color: imported TablePlus colors are often pastel,
        // which made PRODUCTION hard to see. `colorHex` is kept for source compatibility.
        let color = NSColor(hex: environment.defaultColorHex) ?? .systemGray
        let name = environment.displayName.uppercased()
        Tag(compact ? Self.shortName(environment) : name, color: color, style: environment == .production ? .solid : .soft)
    }

    static func shortName(_ environment: ConnectionEnvironment) -> String {
        switch environment {
        case .local: return "LOCAL"
        case .development: return "DEV"
        case .testing: return "TEST"
        case .staging: return "STAGING"
        case .production: return "PROD"
        }
    }
}

// MARK: - Surfaces

/// Rounded raised container with a hairline border.
public struct Card<Content: View>: View {
    var padding: CGFloat
    var content: Content

    public init(padding: CGFloat = DS.Space.l, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous).fill(DS.Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous).strokeBorder(DS.Palette.separator.opacity(0.7), lineWidth: 0.5))
    }
}

/// Uppercase section label with an optional count and trailing accessory.
public struct SectionLabel<Accessory: View>: View {
    var title: String
    var count: Int?
    var accessory: Accessory

    public init(_ title: String, count: Int? = nil, @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.title = title
        self.count = count
        self.accessory = accessory()
    }

    public var body: some View {
        HStack(spacing: DS.Space.s) {
            Text(title.uppercased()).font(DS.Typo.eyebrow).tracking(0.6).foregroundStyle(.secondary)
            if let count {
                Text("\(count)").font(DS.Typo.micro).monospacedDigit().foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            accessory
        }
    }
}

/// Header of a full-pane screen (Insights, Diagram, Diff…): icon, title, subtitle, trailing controls.
public struct PaneHeader<Trailing: View>: View {
    var title: String
    var subtitle: String?
    var systemImage: String
    var tint: Color
    var trailing: Trailing

    public init(_ title: String, subtitle: String? = nil, systemImage: String, tint: Color = .accentColor, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tint = tint
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: DS.Space.l) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).fill(tint.opacity(0.12)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(DS.Typo.headline).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(DS.Typo.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: DS.Space.l)
            trailing
        }
        .padding(.horizontal, DS.Space.xl)
        .frame(height: 52)
        .background(DS.Palette.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

// MARK: - Toolbars

/// Horizontal strip of tool buttons under a tab. When the row is too narrow, labels collapse to icons
/// instead of wrapping onto two lines.
public struct ToolStrip<Leading: View, Trailing: View>: View {
    var leading: Leading
    var trailing: Trailing

    public init(@ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.leading = leading()
        self.trailing = trailing()
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            row(compact: false)
            row(compact: true)
        }
        .padding(.horizontal, DS.Space.m)
        .frame(height: DS.Metrics.toolbarHeight)
        .frame(maxWidth: .infinity)
        .background(DS.Palette.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func row(compact: Bool) -> some View {
        HStack(spacing: DS.Space.xs) {
            leading
            Spacer(minLength: DS.Space.m)
            trailing
        }
        .environment(\.toolStripCompact, compact)
    }
}

private struct ToolStripCompactKey: EnvironmentKey { static let defaultValue = false }

public extension EnvironmentValues {
    /// True when the enclosing `ToolStrip` is too narrow for labels.
    var toolStripCompact: Bool {
        get { self[ToolStripCompactKey.self] }
        set { self[ToolStripCompactKey.self] = newValue }
    }
}

/// Icon + label button for `ToolStrip`. Never wraps; shows only the icon when space is short.
public struct ToolButton: View {
    var title: String
    var systemImage: String
    var shortcut: String?
    var role: ButtonRole?
    var prominent: Bool
    var helpText: String?
    var action: () -> Void
    @Environment(\.toolStripCompact) private var compact
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false

    /// `help` replaces the default tooltip ("Title (shortcut)").
    public init(_ title: String, systemImage: String, shortcut: String? = nil, role: ButtonRole? = nil, prominent: Bool = false,
                help: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.shortcut = shortcut
        self.role = role
        self.prominent = prominent
        self.helpText = help
        self.action = action
    }

    public var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 11.5, weight: .medium)).frame(width: 14)
                if !compact { Text(title).lineLimit(1).fixedSize() }
                if prominent, !compact, let shortcut {
                    Text(shortcut).font(.system(size: 10.5, weight: .medium)).opacity(0.7).fixedSize()
                }
            }
            .font(.system(size: 12, weight: prominent ? .semibold : .regular))
            .foregroundStyle(foreground)
            .padding(.horizontal, compact ? 6 : 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).fill(background))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(helpText ?? shortcut.map { "\(title) (\($0))" } ?? title)
    }

    private var foreground: Color {
        if !enabled { return Color(nsColor: .tertiaryLabelColor) }
        if prominent { return .white }
        if role == .destructive { return .red }
        return .primary.opacity(0.85)
    }

    private var background: Color {
        if prominent { return enabled ? Color.accentColor.opacity(hover ? 0.85 : 1) : Color.accentColor.opacity(0.35) }
        return hover && enabled ? DS.Palette.hover : .clear
    }
}

/// Thin vertical divider between groups of tool buttons.
public struct ToolDivider: View {
    public init() {}
    public var body: some View {
        Rectangle().fill(DS.Palette.separator).frame(width: 1, height: 16).padding(.horizontal, DS.Space.xs)
    }
}

/// Compact segmented control that keeps a fixed size (never stretches across the toolbar).
public struct CompactSegmented<Value: Hashable>: View {
    var options: [(label: String, value: Value)]
    @Binding var selection: Value

    public init(_ options: [(label: String, value: Value)], selection: Binding<Value>) {
        self.options = options
        self._selection = selection
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, o in
                let on = o.value == selection
                Text(o.label)
                    .font(.system(size: 11.5, weight: on ? .semibold : .regular))
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(on ? Color.primary : Color.secondary)
                    .padding(.horizontal, 9)
                    .frame(height: 20)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color(nsColor: .controlBackgroundColor))
                                .shadow(color: .black.opacity(0.12), radius: 0.5, y: 0.5)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { selection = o.value }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06)))
        .fixedSize()
    }
}

// MARK: - Status & empty states

/// Bottom strip with secondary information (row counts, timings, pagination).
public struct StatusBar<Leading: View, Trailing: View>: View {
    var leading: Leading
    var trailing: Trailing

    public init(@ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.leading = leading()
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: DS.Space.l) {
            leading
            Spacer(minLength: DS.Space.m)
            trailing
        }
        .font(DS.Typo.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, DS.Space.l)
        .frame(height: DS.Metrics.statusBarHeight)
        .background(DS.Palette.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// Centered placeholder for empty panes.
public struct EmptyState<Actions: View>: View {
    var systemImage: String
    var title: String
    var message: String?
    var actions: Actions

    public init(_ title: String, systemImage: String, message: String? = nil, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
        self.actions = actions()
    }

    public var body: some View {
        VStack(spacing: DS.Space.l) {
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
                .frame(height: 36)
            VStack(spacing: DS.Space.xs) {
                Text(title).font(DS.Typo.headline)
                if let message {
                    Text(message).font(DS.Typo.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
                }
            }
            HStack(spacing: DS.Space.m) { actions }.controlSize(.regular)
        }
        .padding(DS.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Keyboard shortcut hint ("⌘T") rendered as a key cap.
public struct KeyCap: View {
    var keys: String
    public init(_ keys: String) { self.keys = keys }
    public var body: some View {
        Text(keys)
            .font(.system(size: 10.5, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .frame(height: 17)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(DS.Palette.separator, lineWidth: 0.5))
    }
}

/// Inline message banner (info / warning / error / success).
public struct Banner: View {
    public enum Kind { case info, warning, error, success }
    var kind: Kind
    var text: String

    public init(_ kind: Kind, _ text: String) {
        self.kind = kind
        self.text = text
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.m) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(DS.Typo.callout).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.m)
        // Without a floor, window minimum-size computation measures the text one word per line.
        .frame(minWidth: 240, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).fill(color.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).strokeBorder(color.opacity(0.25), lineWidth: 0.5))
    }

    private var icon: String {
        switch kind {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .success: return "checkmark.circle.fill"
        }
    }

    private var color: Color {
        switch kind {
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        case .success: return .green
        }
    }
}
