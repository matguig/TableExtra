import AppKit
import MTPCore
import MTPUIKit
import SwiftUI

/// Settings → AI (Claude CLI path or API key, depending on the build's backend; model).
public struct AISettingsView: View {
    @AppStorage(AISettings.claudePathKey) private var claudePath = ""
    @AppStorage(AISettings.defaultModelKey) private var defaultModel = "sonnet"
    @AppStorage(AISettings.includeSampleRowsKey) private var includeSampleRows = false
    @AppStorage(AISettings.maxSchemaCharsKey) private var maxSchemaChars = AISettings.defaultMaxSchemaChars

    @State private var detected: String?
    @State private var detecting = false
    @State private var testing = false
    @State private var testResult: (ok: Bool, message: String)?
    @State private var testTask: Task<Void, Never>?
    @State private var keyDraft = ""
    @State private var storedKey: String?
    private let backend = AIBackend.current

    public init() {}

    public var body: some View {
        Form {
            if backend == .api { apiKeySection } else { cliSection }

            Section("Model") {
                Picker("Default model", selection: $defaultModel) {
                    ForEach(AIModels.aliases, id: \.self) { Text(AIModels.displayName($0)).tag($0) }
                }
                LabeledContent("Connection") {
                    HStack(spacing: DS.Space.m) {
                        if let r = testResult {
                            StatusLine(ok: r.ok, text: r.message)
                        } else if !testing {
                            Text(backend == .api ? "Sends a one-word prompt to check the API key." : "Sends a one-word prompt to check the CLI and login.")
                                .font(DS.Typo.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: DS.Space.s)
                        if testing {
                            ProgressView().controlSize(.small)
                            Button("Cancel") { testTask?.cancel() }.fixedSize()
                        } else {
                            Button("Test Connection", action: test).fixedSize()
                        }
                    }
                }
            }

            Section {
                Toggle("Include sample rows in AI context", isOn: $includeSampleRows)
                TextField("Max schema context", value: $maxSchemaChars, format: .number)
                    .monospacedDigit()
            } header: {
                Text("Context")
            } footer: {
                SettingsFootnote("Schema context (in characters) lists tables, columns, keys and enum values; tables named in your question come first. Sample rows (3 per mentioned table) are sent to Claude only when enabled.")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if backend == .api {
                storedKey = AnthropicAPIKey.value
            } else if detected == nil {
                detect()
            }
        }
    }

    private var apiKeySection: some View {
        Section {
            LabeledContent("API key") {
                HStack(spacing: DS.Space.s) {
                    SecureField("API key", text: $keyDraft, prompt: Text(storedKey.map(AnthropicAPIKey.masked) ?? "sk-ant-…"))
                        .labelsHidden()
                        .font(DS.Typo.mono)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(saveKey)
                    Button("Save", action: saveKey).disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty).fixedSize()
                    Button("Remove", role: .destructive) {
                        AnthropicAPIKey.save(nil)
                        storedKey = nil
                        testResult = nil
                    }
                    .disabled(storedKey == nil).fixedSize()
                }
            }
            LabeledContent("Status") {
                if let storedKey {
                    StatusLine(ok: true, text: "Stored in the Keychain (\(AnthropicAPIKey.masked(storedKey)))", mono: true)
                } else {
                    StatusLine(ok: false, text: "No API key yet.")
                }
            }
        } header: {
            Text("Claude API")
        } footer: {
            SettingsFootnote("Create a key at [console.anthropic.com](https://console.anthropic.com/settings/keys). It is kept in your Keychain and sent only to api.anthropic.com. Requests are billed to your Anthropic account.")
        }
    }

    private func saveKey() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        AnthropicAPIKey.save(key)
        storedKey = AnthropicAPIKey.value
        keyDraft = ""
        testResult = nil
    }

    private var cliSection: some View {
        Section {
            LabeledContent("Claude CLI") {
                HStack(spacing: DS.Space.s) {
                    TextField("Claude CLI", text: $claudePath, prompt: Text(detected ?? "Auto-detect"))
                        .labelsHidden()
                        .multilineTextAlignment(.leading)
                        .font(DS.Typo.mono)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse…", action: browse).fixedSize()
                    Button("Detect", action: detect).disabled(detecting).fixedSize()
                }
            }
            LabeledContent("Status") { cliStatus }
        } header: {
            Text("Claude Code")
        } footer: {
            SettingsFootnote("The assistant runs your local `claude` CLI with your Claude Code login (no API key), without saving sessions.")
        }
    }

    @ViewBuilder
    private var cliStatus: some View {
        if detecting {
            HStack(spacing: DS.Space.s) {
                ProgressView().controlSize(.mini)
                Text("Looking for claude…").font(DS.Typo.callout).foregroundStyle(.secondary)
            }
        } else if claudePath.isEmpty {
            if let detected {
                StatusLine(ok: true, text: "Using \(detected)", mono: true)
            } else {
                StatusLine(ok: false, text: "claude was not found. Install Claude Code or choose the binary.")
            }
        } else if !FileManager.default.isExecutableFile(atPath: (claudePath as NSString).expandingTildeInPath) {
            StatusLine(ok: false, text: "No executable at this path.")
        } else {
            StatusLine(ok: true, text: "Using the path above.")
        }
    }

    private func detect() {
        detecting = true
        Task {
            let url = await Task.detached { ClaudeCLI.locate(override: nil) }.value
            detected = url?.path
            detecting = false
        }
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: (claudePath.isEmpty ? (detected ?? "~/.local/bin") : claudePath) as String)
            .deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url { claudePath = url.path }
    }

    private func test() {
        testing = true
        testResult = nil
        let model = defaultModel
        testTask = Task {
            let start = Date()
            do {
                let r = try await AIService.testConnection(model: model)
                let reply = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
                testResult = (true, "\(r.model ?? model) answered “\(reply.prefix(40))” in \(Fmt.duration(Date().timeIntervalSince(start)))")
            } catch {
                testResult = (false, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
            testing = false
        }
    }
}

/// Green check / red cross + one-line message, for settings status rows.
struct StatusLine: View {
    var ok: Bool
    var text: String
    var mono = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .font(.system(size: 11))
                .foregroundStyle(ok ? Color.green : Color.red)
            Text(text)
                .font(mono ? DS.Typo.monoSmall : DS.Typo.callout)
                .foregroundStyle(ok ? Color.secondary : Color(nsColor: NSColor.systemRed.readableText()))
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

/// Footer text under a settings section.
struct SettingsFootnote: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text((try? AttributedString(markdown: text)) ?? AttributedString(text))
            .font(DS.Typo.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Monospaced snippet box with a copy button, for commands and config.
struct CodeSnippet: View {
    var text: String
    var copyLabel = "Copy"

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(DS.Typo.monoSmall)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(.vertical, DS.Space.m)
                    .padding(.leading, DS.Space.m + DS.Space.xxs)
            }
            AIIconButton(systemImage: "doc.on.doc", help: copyLabel, size: 22) { Pasteboard.copy(text) }
                .padding(DS.Space.xs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).strokeBorder(DS.Palette.separator, lineWidth: 0.5))
    }
}
