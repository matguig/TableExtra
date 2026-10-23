import AppKit
import SwiftUI

public extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let hasAlpha = s.count == 8
        let r = CGFloat((v >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = CGFloat((v >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = CGFloat((v >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? CGFloat(v & 0xFF) / 255 : 1
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }

    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }

    /// Black or white, whichever reads better on this color.
    var contrastingText: NSColor {
        guard let c = usingColorSpace(.sRGB) else { return .labelColor }
        let l = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
        return l > 0.6 ? .black : .white
    }
}

public extension Color {
    init?(hex: String) {
        guard let ns = NSColor(hex: hex) else { return nil }
        self.init(nsColor: ns)
    }
}

/// Semantic colors shared by every module (follow light/dark automatically).
public enum MTPColors {
    public static let null = NSColor.tertiaryLabelColor
    public static let editedCell = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua]) != nil ? NSColor(srgbRed: 0.45, green: 0.38, blue: 0.10, alpha: 0.55) : NSColor(srgbRed: 1.0, green: 0.93, blue: 0.62, alpha: 1)
    }
    public static let insertedRow = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua]) != nil ? NSColor(srgbRed: 0.12, green: 0.36, blue: 0.18, alpha: 0.6) : NSColor(srgbRed: 0.84, green: 0.96, blue: 0.84, alpha: 1)
    }
    public static let deletedRow = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua]) != nil ? NSColor(srgbRed: 0.45, green: 0.12, blue: 0.12, alpha: 0.6) : NSColor(srgbRed: 1.0, green: 0.86, blue: 0.86, alpha: 1)
    }

    // SQL syntax palette.
    public static let keyword = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua]) != nil ? NSColor(srgbRed: 0.99, green: 0.37, blue: 0.64, alpha: 1) : NSColor(srgbRed: 0.61, green: 0.14, blue: 0.58, alpha: 1)
    }
    public static let string = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua]) != nil ? NSColor(srgbRed: 0.99, green: 0.42, blue: 0.36, alpha: 1) : NSColor(srgbRed: 0.77, green: 0.10, blue: 0.09, alpha: 1)
    }
    public static let number = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua]) != nil ? NSColor(srgbRed: 0.82, green: 0.75, blue: 0.41, alpha: 1) : NSColor(srgbRed: 0.11, green: 0.0, blue: 0.81, alpha: 1)
    }
    public static let comment = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua]) != nil ? NSColor(srgbRed: 0.42, green: 0.47, blue: 0.53, alpha: 1) : NSColor(srgbRed: 0.36, green: 0.42, blue: 0.47, alpha: 1)
    }
    public static let identifier = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua]) != nil ? NSColor(srgbRed: 0.41, green: 0.83, blue: 0.94, alpha: 1) : NSColor(srgbRed: 0.04, green: 0.37, blue: 0.53, alpha: 1)
    }
    public static let parameter = NSColor.systemOrange
    public static let function = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua]) != nil ? NSColor(srgbRed: 0.40, green: 0.85, blue: 0.62, alpha: 1) : NSColor(srgbRed: 0.20, green: 0.45, blue: 0.27, alpha: 1)
    }
}
