import Foundation

/// UserDefaults keys shared by the AI panel and Settings → AI.
public enum AISettings {
    public static let claudePathKey = "ai.claudePath"
    public static let defaultModelKey = "ai.defaultModel"
    public static let includeSampleRowsKey = "ai.includeSampleRows"
    public static let maxSchemaCharsKey = "ai.maxSchemaChars"

    public static let defaultMaxSchemaChars = 24_000

    /// Tests swap this for a suite.
    nonisolated(unsafe) public static var defaults: UserDefaults = .standard

    /// Explicit path to the claude binary; nil means auto-detect.
    public static var claudePath: String? {
        get {
            let s = defaults.string(forKey: claudePathKey)?.trimmingCharacters(in: .whitespaces) ?? ""
            return s.isEmpty ? nil : s
        }
        set { defaults.set(newValue, forKey: claudePathKey) }
    }

    public static var defaultModel: String {
        get { defaults.string(forKey: defaultModelKey).flatMap { $0.isEmpty ? nil : $0 } ?? "sonnet" }
        set { defaults.set(newValue, forKey: defaultModelKey) }
    }

    /// Off by default: sample rows may contain personal data.
    public static var includeSampleRows: Bool {
        get { defaults.bool(forKey: includeSampleRowsKey) }
        set { defaults.set(newValue, forKey: includeSampleRowsKey) }
    }

    public static var maxSchemaChars: Int {
        get {
            let v = defaults.integer(forKey: maxSchemaCharsKey)
            return v > 0 ? max(2_000, v) : defaultMaxSchemaChars
        }
        set { defaults.set(newValue, forKey: maxSchemaCharsKey) }
    }
}
