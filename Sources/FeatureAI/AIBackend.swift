import Foundation
import MTPCore

/// How this build reaches Claude. Chosen at build time: `scripts/build-app.sh --ai cli|api` writes `TEAIBackend` in
/// Info.plist; `TABLEEXTRA_AI_BACKEND` sets it when running from `swift run`. Defaults to the Claude Code CLI.
public enum AIBackend: String, Sendable, CaseIterable {
    /// The user's local `claude` CLI and Claude Code login (not usable from a sandboxed app).
    case cli
    /// The Claude API with the user's own API key, kept in the Keychain (works in a sandboxed app).
    case api

    public static let infoKey = "TEAIBackend"
    public static let environmentKey = "TABLEEXTRA_AI_BACKEND"

    /// Tests swap it.
    nonisolated(unsafe) public static var current: AIBackend = resolve(
        info: Bundle.main.object(forInfoDictionaryKey: infoKey) as? String,
        environment: ProcessInfo.processInfo.environment[environmentKey])

    /// The environment wins over Info.plist so one build can be tried both ways.
    static func resolve(info: String?, environment: String?) -> AIBackend {
        for value in [environment, info] {
            if let v = value?.trimmingCharacters(in: .whitespaces).lowercased(), let backend = AIBackend(rawValue: v) { return backend }
        }
        return .cli
    }
}

/// The model choices offered in the UI (aliases, as the CLI takes them) and their Claude API ids.
public enum AIModels {
    public static let aliases = ["sonnet", "opus", "haiku"]

    public static func apiID(for alias: String) -> String {
        switch alias.lowercased() {
        case "opus": return "claude-opus-5-5"
        case "haiku": return "claude-haiku-5-5"
        case "sonnet", "": return "claude-sonnet-5-5"
        default: return alias  // already a model id
        }
    }

    /// "Sonnet", or "Sonnet 5.5" when the API backend pins the version.
    public static func displayName(_ alias: String, backend: AIBackend = AIBackend.current) -> String {
        guard backend == .api, aliases.contains(alias) else { return alias.capitalized }
        return alias.capitalized + " 5.5"
    }
}

/// The Anthropic API key, stored in the Keychain only.
public enum AnthropicAPIKey {
    static let account = "anthropic.api-key"

    public static var value: String? { Keychain.get(account: account) }
    public static var isSet: Bool { value?.isEmpty == false }

    public static func save(_ key: String?) {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.set(trimmed?.isEmpty == false ? trimmed : nil, account: account)
    }

    /// "sk-ant-…a1b2", for display.
    public static func masked(_ key: String) -> String {
        guard key.count > 12 else { return String(repeating: "•", count: key.count) }
        return String(key.prefix(7)) + "…" + String(key.suffix(4))
    }
}
