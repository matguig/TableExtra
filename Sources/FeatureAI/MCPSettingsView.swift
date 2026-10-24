import AppKit
import MTPCore
import MTPUIKit
import SwiftUI

/// Settings → MCP (install tableextra-mcp into Claude Code, audit log).
public struct MCPSettingsView: View {
    private enum Pending: Identifiable {
        case add, remove
        var id: Int { self == .add ? 0 : 1 }
    }

    @State private var status: String?
    @State private var installed: Bool?
    @State private var busy = false
    @State private var pending: Pending?
    @State private var lastOutput: String?
    @State private var connections: [ConnectionConfig] = []
    @State private var audit: [MCPInstaller.AuditEntry] = []
    @State private var auditFilter = ""

    private let binary = MCPInstaller.binaryURL()
    /// The API build never runs the `claude` CLI: it only shows the command to copy.
    private let usesCLI = AIBackend.current == .cli

    public init() {}

    public var body: some View {
        Form {
            serverSection
            clientsSection
            connectionsSection
            auditSection
        }
        .formStyle(.grouped)
        .onAppear {
            reloadLocal()
            if usesCLI { refreshStatus() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .mtpConnectionsDidChange)) { _ in reloadLocal() }
        .confirmationDialog(pending == .add ? "Add TableExtra to Claude Code?" : "Remove TableExtra from Claude Code?",
                            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            presenting: pending) { p in
            Button(p == .add ? "Add" : "Remove", role: p == .remove ? .destructive : nil) { run(p) }
            Button("Cancel", role: .cancel) {}
        } message: { p in
            Text("This runs:\n\(command(p))")
        }
    }

    private func command(_ p: Pending) -> String {
        MCPInstaller.displayCommand(p == .add ? MCPInstaller.addArguments(binaryPath: binary.path) : MCPInstaller.removeArguments())
    }

    private var serverSection: some View {
        Section {
            LabeledContent("Server binary") {
                Text(binary.path).font(DS.Typo.monoSmall).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(binary.path)
            }
            if !FileManager.default.isExecutableFile(atPath: binary.path) {
                Banner(.warning, "The binary is missing at this path. Build it with `swift build --product tableextra-mcp`.")
            }
            if usesCLI {
                LabeledContent("Claude Code") {
                    HStack(spacing: DS.Space.s) {
                        if busy { ProgressView().controlSize(.small) }
                        switch installed {
                        case .some(true): Tag("INSTALLED", color: .systemGreen, systemImage: "checkmark")
                        case .some(false): Tag("NOT INSTALLED", color: .systemGray)
                        case .none: Tag("UNKNOWN", color: .systemGray, style: .outline)
                        }
                    }
                }
                if let status, !status.isEmpty {
                    Text(status).font(DS.Typo.monoSmall).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(8)
                }
            }
            VStack(alignment: .leading, spacing: DS.Space.m) {
                CodeSnippet(text: MCPInstaller.displayCommand(MCPInstaller.addArguments(binaryPath: binary.path)), copyLabel: "Copy command")
                if usesCLI {
                    HStack(spacing: DS.Space.s) {
                        Button("Add to Claude Code…") { pending = .add }.disabled(busy)
                        Button("Remove…") { pending = .remove }.disabled(busy || installed == false)
                        Spacer(minLength: DS.Space.s)
                        Button("Refresh", action: refreshStatus).disabled(busy)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let lastOutput {
                Text(lastOutput).font(DS.Typo.monoSmall).textSelection(.enabled).lineLimit(6)
            }
        } header: {
            Text("tableextra-mcp")
        } footer: {
            SettingsFootnote("Gives Claude Code read-only schema and query tools on your saved connections (per-connection access below). Writes are refused on production and staging. Every call is logged."
                + (usesCLI ? "" : " Run the command above in a terminal to add it to Claude Code."))
        }
    }

    private var clientsSection: some View {
        Section {
            CodeSnippet(text: MCPInstaller.jsonSnippet(binaryPath: binary.path), copyLabel: "Copy JSON")
        } header: {
            Text("Other MCP clients")
        } footer: {
            SettingsFootnote("Add this to the MCP configuration of any other client.")
        }
    }

    private var connectionsSection: some View {
        Section {
            if connections.isEmpty {
                Text("No saved connections.").foregroundStyle(.secondary)
            }
            ForEach(connections, id: \.id) { c in connectionRow(c) }
        } header: {
            Text("Connections visible to agents")
        } footer: {
            SettingsFootnote("Change access in each connection's settings.")
        }
    }

    private func connectionRow(_ c: ConnectionConfig) -> some View {
        HStack(spacing: DS.Space.m) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous).fill(c.accentColor).frame(width: 3, height: 16)
            Text(c.name.isEmpty ? c.subtitle : c.name).lineLimit(1)
            EnvironmentTag(environment: c.environment, colorHex: c.colorHex)
            Spacer(minLength: DS.Space.m)
            if c.mcpAccess == .readWrite && c.isProductionLike {
                Image(systemName: "lock.fill").font(DS.Typo.caption).foregroundStyle(.secondary)
                    .help("Writes are always refused on \(c.environment.displayName.lowercased()) connections")
            }
            accessTag(c.mcpAccess)
        }
    }

    private func accessTag(_ access: MCPAccess) -> some View {
        switch access {
        case .none: return Tag("HIDDEN", color: .systemGray, style: .outline, systemImage: "eye.slash").help(access.displayName)
        case .readOnly: return Tag("READ-ONLY", color: .systemBlue, systemImage: "eye").help(access.displayName)
        case .readWrite: return Tag("READ & WRITE", color: .systemOrange, systemImage: "pencil").help(access.displayName)
        }
    }

    private var filteredAudit: [MCPInstaller.AuditEntry] {
        let f = auditFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !f.isEmpty else { return audit }
        return audit.filter {
            [$0.tool, $0.connection ?? "", $0.sql ?? "", $0.status, $0.outcome].contains { $0.lowercased().contains(f) }
        }
    }

    private var auditSection: some View {
        Section {
            HStack(spacing: DS.Space.s) {
                TextField("Filter", text: $auditFilter, prompt: Text("Filter by tool, connection, SQL…"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                AIIconButton(systemImage: "arrow.clockwise", help: "Reload", action: reloadLocal)
                AIIconButton(systemImage: "folder", help: "Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.mcpAuditLog]) }
                    .disabled(!FileManager.default.fileExists(atPath: AppPaths.mcpAuditLog.path))
            }
            if audit.isEmpty {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: "list.bullet.rectangle").foregroundStyle(.tertiary)
                    Text("No MCP activity yet.").font(DS.Typo.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                Table(filteredAudit) {
                    TableColumn("Time") { e in
                        Text(e.date.map { $0.formatted(date: .abbreviated, time: .standard) } ?? e.ts).font(.caption)
                    }
                    .width(min: 110, ideal: 140)
                    TableColumn("Tool") { e in Text(e.tool).font(.caption) }.width(min: 70, ideal: 100)
                    TableColumn("Connection") { e in Text(e.connection ?? "—").font(.caption) }.width(min: 60, ideal: 90)
                    TableColumn("Status") { e in
                        Tag(e.status.uppercased(), color: e.status == "ok" ? .systemGreen : e.status == "refused" ? .systemOrange : .systemRed)
                    }
                    .width(min: 56, ideal: 64)
                    TableColumn("ms") { e in Text("\(e.duration_ms)").font(DS.Typo.caption).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing) }.width(44)
                    TableColumn("SQL / outcome") { e in
                        Text(e.sql.map { "\($0)  → \(e.outcome)" } ?? e.outcome)
                            .font(DS.Typo.monoSmall)
                            .lineLimit(2)
                            .help((e.sql ?? "") + "\n\n" + e.outcome)
                    }
                }
                .frame(minHeight: 220)
            }
        } header: {
            Text("Audit log")
        }
    }

    private func reloadLocal() {
        connections = ConnectionStore.shared.connections
        audit = MCPInstaller.readAuditLog()
    }

    private func refreshStatus() {
        busy = true
        Task {
            do {
                let cli = try await Task.detached { try ClaudeCLI.resolved() }.value
                let out = try await cli.run(MCPInstaller.getArguments(), timeout: 30)
                installed = out.status == 0
                status = (out.status == 0 ? out.stdout : out.stderr.isEmpty ? out.stdout : out.stderr)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                installed = nil
                status = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            busy = false
        }
    }

    private func run(_ p: Pending) {
        busy = true
        lastOutput = nil
        let args = p == .add ? MCPInstaller.addArguments(binaryPath: binary.path) : MCPInstaller.removeArguments()
        Task {
            do {
                let cli = try await Task.detached { try ClaudeCLI.resolved() }.value
                let out = try await cli.run(args, timeout: 30)
                lastOutput = [out.stdout, out.stderr].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }.joined(separator: "\n")
                if out.status != 0 && (lastOutput ?? "").isEmpty { lastOutput = "claude exited with status \(out.status)" }
            } catch {
                lastOutput = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            busy = false
            refreshStatus()
        }
    }
}
