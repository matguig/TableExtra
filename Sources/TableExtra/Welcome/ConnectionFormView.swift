import AppKit
import MTPCore
import MTPUIKit
import SwiftUI

struct ConnectionFormView: View {
    @State var draft: ConnectionDraft
    var onClose: () -> Void

    @State private var testState: TestState = .idle
    @State private var showAdvanced = false
    @State private var extraOptionsText = ""
    @State private var portText = ""
    @State private var hostKey: SSHKnownHosts.Entry?

    enum TestState: Equatable {
        case idle, running, ok(String), failed(String)
    }

    private var groups: [ConnectionGroup] { ConnectionStore.shared.groups }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        identity
                        if draft.config.driver == .postgres { postgresFields } else { sqliteFields }
                        safety
                        claudeFields
                        if draft.config.driver == .postgres { awsFields.id("aws") }
                        if draft.config.driver == .postgres { sshFields.id("ssh") }
                        DisclosureGroup("Advanced", isExpanded: $showAdvanced) { advanced.padding(.top, 8) }
                    }
                    .padding(20)
                }
                .onReceive(NotificationCenter.default.publisher(for: .mtpConnectionFormScroll)) { note in
                    if let section = note.object as? String { proxy.scrollTo(section, anchor: .top) }
                }
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 640)
        .onAppear {
            portText = draft.config.port.map(String.init) ?? ""
            extraOptionsText = draft.config.extraOptions.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            DriverBadge(driver: draft.config.driver, colorHex: draft.config.effectiveColorHex, size: 38)
            VStack(alignment: .leading) {
                Text(draft.isNew ? "New Connection" : "Edit Connection").font(.headline)
                Text(draft.config.driver.displayName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if draft.isNew {
                Picker("", selection: $draft.config.driver) {
                    ForEach(DriverKind.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .onChange(of: draft.config.driver) { _, d in
                    if d == .postgres, draft.config.port == nil { draft.config.port = 5432; portText = "5432" }
                }
            }
        }
        .padding(16)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("Name") { TextField("My database", text: $draft.config.name) }
            row("Environment") {
                Picker("", selection: $draft.config.environment) {
                    ForEach(ConnectionEnvironment.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .onChange(of: draft.config.environment) { old, env in
                    // Follow the environment defaults unless the user customised them.
                    if draft.config.safety == old.defaultSafety { draft.config.safety = env.defaultSafety }
                    if draft.config.colorHex == nil || draft.config.colorHex == old.defaultColorHex { draft.config.colorHex = nil }
                    draft.config.dryRunWrites = env == .production || env == .staging
                    if env == .production, draft.config.mcpAccess == .readWrite { draft.config.mcpAccess = .readOnly }
                }
            }
            row("Color") {
                HStack(spacing: 6) {
                    ForEach(ColorPresets.all, id: \.self) { hex in
                        Circle().fill(Color(hex: hex) ?? .gray).frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(Color.primary, lineWidth: draft.config.effectiveColorHex.uppercased() == hex ? 2 : 0))
                            .onTapGesture { draft.config.colorHex = hex }
                    }
                    Button("Default") { draft.config.colorHex = nil }.buttonStyle(.link).font(.caption)
                }
            }
            row("Group") {
                Picker("", selection: $draft.config.groupID) {
                    Text("None").tag(UUID?.none)
                    ForEach(groups) { Text($0.name).tag(UUID?.some($0.id)) }
                }
                .labelsHidden()
            }
        }
    }

    private var postgresFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Server") {
                Button("Paste URL") { pasteURL() }.buttonStyle(.link).font(DS.Typo.callout)
            }
            .padding(.top, DS.Space.s)
            row("Host") { TextField("127.0.0.1", text: $draft.config.host) }
            row("Port") {
                TextField("5432", text: $portText).frame(width: 90)
                    .onChange(of: portText) { _, v in draft.config.port = Int(v) }
            }
            row("User") { TextField("postgres", text: $draft.config.user) }
            row("Password") { SecureField("Stored in the macOS Keychain", text: $draft.password) }
            row("Database") { TextField("postgres", text: $draft.config.database) }
            row("SSL mode") {
                Picker("", selection: $draft.config.sslMode) {
                    ForEach(SSLMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 160)
            }
        }
    }

    private var sqliteFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Database file").font(.subheadline.weight(.semibold))
            HStack {
                TextField("~/data/app.sqlite", text: $draft.config.filePath)
                Button("Choose…") { chooseFile(create: false) }
                Button("New…") { chooseFile(create: true) }
            }
        }
    }

    private var safety: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Safety").padding(.top, DS.Space.s)
            row("Writes") {
                Picker("", selection: $draft.config.safety) {
                    ForEach(SafetyLevel.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
            }
            Toggle("Dry-run writes first and show how many rows they touch", isOn: $draft.config.dryRunWrites)
                .disabled(draft.config.driver != .postgres)
            Toggle("Block UPDATE / DELETE without WHERE unless confirmed", isOn: $draft.config.guardUnboundedWrites)
            row("AI agents (MCP)") {
                Picker("", selection: $draft.config.mcpAccess) {
                    ForEach(MCPAccess.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
            }
            if draft.config.environment == .production && draft.config.mcpAccess == .readWrite {
                Label("Agents can never write to production connections, even with this setting.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Claude context for this connection: the app's code repository and whether it may read data.
    private var claudeFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Claude").padding(.top, DS.Space.s)
            row("Code repository") {
                HStack {
                    TextField("Optional — e.g. ~/Developer/my-app", text: Binding(
                        get: { draft.config.codeRepository ?? "" },
                        set: { draft.config.codeRepository = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }))
                    Button("Choose…") { chooseRepository() }
                }
            }
            if let repo = draft.config.codeRepository, !repo.isEmpty, draft.config.codeRepositoryURL == nil {
                Label("This folder does not exist.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            } else {
                Text("Claude reads this code (read-only: models, migrations, Kysely types, queries) to answer with your app's context.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            row("Data access") {
                Toggle(isOn: Binding(get: { draft.config.effectiveClaudeCanQuery }, set: { draft.config.claudeCanQuery = $0 })) {
                    Text("Claude can run read-only queries and read rows")
                }
            }
            Text(draft.config.isProductionLike
                 ? "Off by default on staging and production: rows are sent to Anthropic when Claude reads them."
                 : "When off, Claude only sees the schema. Rows read by Claude are sent to Anthropic.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: AWS RDS

    private var awsBinding: Binding<AWSSettings> {
        Binding(get: { draft.config.aws ?? AWSSettings(isEnabled: draft.config.rdsEndpoint != nil) },
                set: { draft.config.aws = $0 })
    }

    /// RDS / CloudWatch / Performance Insights through the `aws` CLI with one of the user's profiles (read-only).
    private var awsFields: some View {
        let ep = draft.config.rdsEndpoint
        return VStack(alignment: .leading, spacing: 10) {
            SectionLabel("AWS RDS").padding(.top, DS.Space.s)
            row("Monitoring") {
                Toggle("Show RDS metrics, events and Performance Insights", isOn: awsBinding.isEnabled)
            }
            if let ep {
                Text("Detected from the host: \(ep.kind == .cluster ? "Aurora cluster" : ep.kind == .proxy ? "RDS Proxy" : "DB instance") “\(ep.identifier)” in \(ep.region).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if awsBinding.wrappedValue.isEnabled {
                row("AWS profile") {
                    Picker("", selection: Binding(get: { awsBinding.wrappedValue.profile ?? "" },
                                                  set: { awsBinding.wrappedValue.profile = $0.isEmpty ? nil : $0 })) {
                        Text("Default").tag("")
                        ForEach(AWSProfileList.names(), id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                }
                row("Region") {
                    TextField(ep?.region ?? "us-east-1", text: Binding(get: { awsBinding.wrappedValue.region ?? "" },
                                                                       set: { awsBinding.wrappedValue.region = $0.isEmpty ? nil : $0 }))
                }
                row("Identifier") {
                    HStack {
                        TextField(ep?.identifier ?? "DB instance or cluster identifier", text: Binding(
                            get: { awsBinding.wrappedValue.identifier ?? "" },
                            set: { awsBinding.wrappedValue.identifier = $0.isEmpty ? nil : $0 }))
                        Toggle("Aurora cluster", isOn: awsBinding.isCluster).fixedSize()
                    }
                }
                Text("Read-only: TableExtra runs `aws rds describe-*`, `cloudwatch get-metric-data` and `pi describe-dimension-keys` with this profile. No keys are stored in TableExtra.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func chooseRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the code repository that uses this database"
        if panel.runModal() == .OK, let url = panel.url {
            draft.config.codeRepository = (url.path as NSString).abbreviatingWithTildeInPath
        }
    }

    private var sshFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Connect over SSH tunnel", isOn: $draft.config.ssh.enabled).font(.subheadline.weight(.semibold))
            if draft.config.ssh.enabled {
                row("SSH host") { TextField("bastion.example.com or a ~/.ssh/config alias", text: $draft.config.ssh.host) }
                row("SSH port") { TextField("22", value: $draft.config.ssh.port, format: .number.grouping(.never)).frame(width: 90) }
                row("SSH user") { TextField("ec2-user", text: $draft.config.ssh.user) }
                row("Private key") {
                    HStack {
                        TextField("Optional: ssh-agent and ~/.ssh keys otherwise", text: $draft.config.ssh.privateKeyPath)
                        Button("Choose…") { chooseKey() }
                    }
                }
                if !draft.config.ssh.privateKeyPath.isEmpty {
                    row("Key passphrase") { SecureField("Only for an encrypted key", text: $draft.sshKeyPassphrase) }
                }
                row("SSH password") { SecureField("Optional, stored in the macOS Keychain", text: $draft.sshPassword) }
                Text("""
                    Built-in SSH client: no ssh process is launched. Without a private key it tries the password,                     then ~/.ssh/config IdentityFile keys, ssh-agent and ~/.ssh/id_* keys. HostName, User and Port from                     ~/.ssh/config apply; ProxyJump is not supported.
                    """)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let hostKey {
                    HStack(spacing: DS.Space.s) {
                        Image(systemName: "checkmark.shield").foregroundStyle(.secondary)
                        Text("Trusted host key: \(hostKey.type) \(hostKey.fingerprint)")
                            .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                        Button("Forget Host Key") { forgetHostKey() }
                            .controlSize(.small)
                            .help("Accept the server's current key on the next connection. Only do this if you know why the key changed.")
                    }
                }
            }
        }
        .onAppear(perform: refreshHostKey)
        .onChange(of: draft.config.ssh) { _, _ in refreshHostKey() }
    }

    /// The SSH server's saved key, looked up with ~/.ssh/config applied (HostName / Port).
    private func sshHostAndPort() -> (host: String, port: Int)? {
        guard draft.config.ssh.enabled, let e = try? SSHTunnel.endpoint(for: draft.config.ssh, secrets: ConnectionSecrets()) else { return nil }
        return (e.host, e.port)
    }

    private func refreshHostKey() {
        hostKey = sshHostAndPort().flatMap { SSHKnownHosts.shared.entry(host: $0.host, port: $0.port) }
    }

    private func forgetHostKey() {
        guard let target = sshHostAndPort() else { return }
        SSHKnownHosts.shared.forget(host: target.host, port: target.port)
        refreshHostKey()
        if case .failed = testState { testState = .idle }
    }

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("Default schema") {
                TextField(draft.config.driver == .sqlite ? "main" : "public", text: Binding(
                    get: { draft.config.defaultSchema ?? "" }, set: { draft.config.defaultSchema = $0.isEmpty ? nil : $0 }))
            }
            row("Rows per page") {
                TextField("\(AppSettings.pageSize)", value: $draft.config.pageSize, format: .number.grouping(.never)).frame(width: 90)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Startup SQL (runs on every new session)").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $draft.config.startupSQL).font(.system(.body, design: .monospaced)).frame(height: 60)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.3)))
            }
            if draft.config.driver == .postgres {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Extra libpq options, one key=value per line (application_name, connect_timeout, options…)").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $extraOptionsText).font(.system(.body, design: .monospaced)).frame(height: 50)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.3)))
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Test") { test() }.disabled(testState == .running)
            switch testState {
            case .idle: EmptyView()
            case .running: ProgressView().controlSize(.small)
            case .ok(let msg): Label(msg, systemImage: "checkmark.circle.fill").foregroundStyle(.green).lineLimit(1)
            case .failed(let msg): Label(msg, systemImage: "xmark.octagon.fill").foregroundStyle(.red).lineLimit(2).help(msg)
            }
            Spacer()
            Button("Cancel", role: .cancel) { onClose() }.keyboardShortcut(.cancelAction)
            Button("Save") { save(); onClose() }
            Button("Connect") {
                let c = save()
                onClose()
                AppDelegate.shared.openWorkspace(c)
                AppDelegate.shared.closeWelcome()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
        .padding(14)
    }

    private func row<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).frame(width: 110, alignment: .trailing).foregroundStyle(.secondary)
            content().textFieldStyle(.roundedBorder)
        }
    }

    private func normalized() -> ConnectionConfig {
        var c = draft.config
        c.extraOptions = Dictionary(extraOptionsText.split(separator: "\n").compactMap { line -> (String, String)? in
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return parts.count == 2 && !parts[0].isEmpty ? (parts[0], parts[1]) : nil
        }, uniquingKeysWith: { _, b in b })
        if c.name.trimmingCharacters(in: .whitespaces).isEmpty {
            c.name = c.driver == .sqlite ? (c.filePath as NSString).lastPathComponent : (c.database.isEmpty ? c.host : "\(c.database) @ \(c.host)")
        }
        return c
    }

    @discardableResult
    private func save() -> ConnectionConfig {
        let c = normalized()
        ConnectionStore.shared.upsert(c, secrets: draft.secrets)
        return c
    }

    private func test() {
        testState = .running
        let c = normalized()
        let secrets = draft.secrets
        Task {
            let started = Date()
            let client = DBClient(config: c, secrets: secrets, label: "test")
            do {
                let info = try await client.connect()
                testState = .ok("\(info.product) \(info.version) — \(Fmt.duration(Date().timeIntervalSince(started)))")
            } catch {
                testState = .failed(error.localizedDescription)
            }
            client.close()
            refreshHostKey()
        }
    }

    private func pasteURL() {
        guard let s = NSPasteboard.general.string(forType: .string), let (parsed, secrets) = ConnectionURL.parse(s) else { NSSound.beep(); return }
        draft.config.host = parsed.host
        draft.config.port = parsed.port ?? 5432
        portText = String(draft.config.port ?? 5432)
        draft.config.user = parsed.user
        draft.config.database = parsed.database
        draft.config.sslMode = parsed.sslMode
        if draft.config.name.isEmpty { draft.config.name = parsed.name }
        if let p = secrets.password { draft.password = p }
    }

    private func chooseFile(create: Bool) {
        if create {
            guard let url = FilePanels.chooseSaveURL(suggestedName: "database.sqlite", types: [.database]) else { return }
            draft.config.filePath = url.path
        } else {
            let panel = NSOpenPanel()
            panel.allowsOtherFileTypes = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            draft.config.filePath = url.path
        }
        if draft.config.name.isEmpty { draft.config.name = (draft.config.filePath as NSString).lastPathComponent }
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.config.ssh.privateKeyPath = (url.path as NSString).abbreviatingWithTildeInPath
    }
}

/// Profile names from ~/.aws/config and ~/.aws/credentials: only the [section] headers are kept, nothing else.
enum AWSProfileList {
    static func names() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".aws")
        var names = Set<String>()
        for (file, prefix) in [("config", "profile "), ("credentials", "")] {
            guard let text = try? String(contentsOf: home.appendingPathComponent(file), encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("["), t.hasSuffix("]") else { continue }
                var name = String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                if file == "config" {
                    if name == "default" { names.insert(name); continue }
                    guard name.hasPrefix(prefix) else { continue }   // sso-session / services sections
                    name = String(name.dropFirst(prefix.count))
                }
                if !name.isEmpty { names.insert(name) }
            }
        }
        return names.sorted()
    }
}

