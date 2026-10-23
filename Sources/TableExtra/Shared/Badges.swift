import MTPCore
import MTPUIKit
import SwiftUI

/// Rounded driver tile ("Pg", "SL") tinted with the connection color, like TablePlus.
struct DriverBadge: View {
    var driver: DriverKind
    var colorHex: String
    var size: CGFloat = 34

    /// Light (pastel) tiles get the same hue darkened; saturated tiles get white.
    private var textColor: Color {
        let ns = NSColor(hex: colorHex) ?? .controlAccentColor
        guard let c = ns.usingColorSpace(.sRGB) else { return .white }
        let l = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
        return l > 0.72 ? Color(nsColor: ns.blended(withFraction: 0.62, of: .black) ?? .black) : .white
    }

    var body: some View {
        let color = Color(hex: colorHex) ?? .accentColor
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).strokeBorder(.black.opacity(0.08), lineWidth: 0.5)
            )
            .overlay(
                Text(driver.shortName)
                    .font(.system(size: size * 0.36, weight: .semibold, design: .rounded))
                    .foregroundStyle(textColor)
            )
    }
}

struct EnvironmentBadge: View {
    var environment: ConnectionEnvironment
    var colorHex: String?
    var compact = false

    var body: some View {
        EnvironmentTag(environment: environment, colorHex: colorHex, compact: compact)
    }
}

struct SafetyBadge: View {
    var level: SafetyLevel

    var body: some View {
        switch level {
        case .silent: EmptyView()
        case .confirmWrites: Label("Warning", systemImage: "exclamationmark.shield").labelStyle(.iconOnly).foregroundStyle(.orange).help(level.displayName)
        case .protectedWrites: Label("Safe", systemImage: "touchid").labelStyle(.iconOnly).foregroundStyle(.red).help(level.displayName)
        case .readOnly: Label("Read-only", systemImage: "lock.fill").labelStyle(.iconOnly).foregroundStyle(.blue).help(level.displayName)
        }
    }
}

/// Swatches offered in the connection form (TablePlus preset family + environment colors).
enum ColorPresets {
    static let all = ["#8E8E93", "#34C759", "#30B0C7", "#5AC8FA", "#007AFF", "#5856D6", "#AF52DE", "#FF2D55", "#FF3B30", "#FF9F0A", "#FFCC00", "#A2845E"]
}
