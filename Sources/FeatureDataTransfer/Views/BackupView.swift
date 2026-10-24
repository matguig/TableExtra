import AppKit
import MTPCore
import MTPUIKit
import SwiftUI

/// Server facts and PostgreSQL tools shared by Backup and Restore.
@MainActor
class ProcessTaskModel: ObservableObject {
    let connection: ConnectionConfig
    let database: String
    private let providedSecrets: ConnectionSecrets?

    @Published var serverMajor: Int?
    @Published var serverVersion: String?
    @Published var infoError: String?
    @Published var running = false
    @Published var startedAt: Date?
    @Published var endedAt: Date?
    @Published var resultMessage: (Banner.Kind, String)?
    let log = ProcessLog()
    var runner: ProcessRunner?
    var task: Task<Void, Never>?

    init(connection: ConnectionConfig, database: String?, secrets: ConnectionSecrets?) {
        self.connection = connection
        self.database = database ?? connection.database
        self.providedSecrets = secrets
    }

    var isPostgres: Bool { connection.driver == .postgres }

    var secrets: ConnectionSecrets { providedSecrets ?? ConnectionStore.shared.secrets(for: connection.id) }

    var configForDatabase: ConnectionConfig {
        var c = connection
        if isPostgres && !database.isEmpty { c.database = database }
        return c
    }

    /// Opens a short-lived connection to read the server version; `body` may run more metadata queries.
    func loadServerInfo(_ body: ((DBClient) async throws -> Void)? = nil) async {
        guard isPostgres else { return }
        let client = DBClient(config: configForDatabase, secrets: secrets, label: "backup-info")
        defer { client.close() }
        do {
            let r = try await client.query("SELECT current_setting('server_version_num'), current_setting('server_version')")
            serverMajor = PGToolLocator.serverMajor(versionNum: Int(r.rows.first?[0] ?? "") ?? 0)
            serverVersion = r.rows.first?[1] ?? nil
            try await body?(client)
        } catch {
            infoError = (error as? DatabaseError)?.fullMessage ?? error.localizedDescription
        }
    }

    func toolWarning(_ tool: PGTool?, name: String) -> String? {
        guard isPostgres else { return nil }
        guard let tool else {
            return "\(name) was not found (this build has no built-in copy). Install it with `brew install libpq`, or set the folder with "
                + "`defaults write fr.koa-dev.TableExtra \(PGToolLocator.directoryDefaultsKey) /path/to/bin`."
        }
        if let serverMajor, tool.major < serverMajor {
            return "\(name) \(tool.version) is older than the server (PostgreSQL \(serverVersion ?? String(serverMajor))); "
                + "it will refuse to run. Update TableExtra or install a newer client (brew install libpq)."
        }
        return nil
    }

    /// Runs one command-line tool with live log, through an SSH tunnel when the connection uses one.
    func runProcess(database: String, make: @escaping (PGConnectionTarget) -> ProcessRunner, onSuccess: @escaping () -> String) {
        log.clear()
        resultMessage = nil
        running = true
        startedAt = Date()
        endedAt = nil
        let config = connection
        let secrets = secrets
        let password = secrets.password
        let pending = PendingLines()
        task = Task {
            do {
                let outcome = try await BackupEngine.withEndpoint(config, secrets: secrets, log: { line in Task { @MainActor in self.log.append(line) } }) { host, port in
                    let target = PGConnectionTarget(config: config, password: password, database: database, host: host, port: port)
                    let runner = make(target)
                    await MainActor.run {
                        self.runner = runner
                        self.log.append("$ " + runner.commandLine)
                    }
                    if Task.isCancelled { runner.terminate() }
                    return try await runner.run { _, line in
                        pending.append(line)
                        Task { @MainActor in self.drain(pending) }
                    }
                }
                drain(pending)
                if outcome.wasTerminated {
                    resultMessage = (.warning, "Cancelled.")
                } else if outcome.succeeded {
                    resultMessage = (.success, onSuccess())
                } else {
                    resultMessage = (.error, "Failed with exit status \(outcome.status). See the log for details.")
                }
            } catch {
                resultMessage = (.error, error.localizedDescription)
            }
            endedAt = Date()
            running = false
            runner = nil
        }
    }

    /// Appends buffered process output in order; also called once the process ended so no line is missed.
    private func drain(_ pending: PendingLines) {
        for line in pending.take() { log.append(line) }
    }

    func runLocal(_ work: @escaping @Sendable () async throws -> String) {
        log.clear()
        resultMessage = nil
        running = true
        startedAt = Date()
        endedAt = nil
        task = Task {
            do {
                let message = try await work()
                log.append(message)
                resultMessage = (.success, message)
            } catch {
                resultMessage = (.error, error.localizedDescription)
            }
            endedAt = Date()
            running = false
        }
    }

    func cancel() {
        runner?.terminate()
        task?.cancel()
    }
}

@MainActor
final class BackupModel: ProcessTaskModel {
    enum TableMode: String, CaseIterable, Identifiable {
        case all = "All tables"
        case only = "Only selected"
        case except = "All except selected"
        var id: String { rawValue }
    }

    @Published var tools: [PGTool] = []
    @Published var tool: PGTool?
    @Published var options = PGDumpOptions()
    @Published var schemas: [String] = []
    @Published var selectedSchemas: Set<String> = []
    @Published var tables: [PGTableRef] = []
    @Published var tableMode: TableMode = .all
    @Published var selectedTables: Set<PGTableRef> = []
    @Published var tableFilter = ""
    @Published var compress = false
    @Published var compressionLevel = 6
    @Published var output: URL
    @Published var outputCustomized = false
    @Published var loaded = false

    override init(connection: ConnectionConfig, database: String?, secrets: ConnectionSecrets?) {
        let db = database ?? connection.database
        output = BackupNaming.defaultURL(connection: connection, database: connection.driver == .sqlite ? "" : db,
                                         fileExtension: connection.driver == .sqlite ? "sqlite" : PGDumpOptions.Format.custom.fileExtension)
        super.init(connection: connection, database: database, secrets: secrets)
    }

    func load() async {
        guard isPostgres else { loaded = true; return }
        let found = await Task.detached { PGToolLocator.candidates("pg_dump") }.value
        tools = found
        await loadServerInfo { client in
            let introspector = Introspection.make(client)
            let schemas = try await introspector.schemas(includeSystem: false)
            var tables: [PGTableRef] = []
            for s in schemas {
                let objects = (try? await introspector.objects(in: s)) ?? []
                tables += objects.filter { $0.kind == .table }.map { PGTableRef(schema: s, name: $0.name) }
            }
            self.schemas = schemas
            self.tables = tables.sorted()
        }
        tool = PGToolLocator.preferred("pg_dump", serverMajor: serverMajor, among: tools)
        loaded = true
    }

    func formatChanged() {
        guard !outputCustomized else { return }
        output = BackupNaming.defaultURL(connection: connection, database: database, fileExtension: options.format.fileExtension)
    }

    func chooseOutput() {
        let url: URL?
        if options.format == .directory {
            url = Panels.chooseFolder(prompt: "Choose Parent Folder").map { $0.appendingPathComponent(output.lastPathComponent) }
        } else {
            url = FilePanels.chooseSaveURL(suggestedName: output.lastPathComponent, types: [.data])
        }
        if let url {
            output = url
            outputCustomized = true
        }
    }

    var filteredTables: [PGTableRef] {
        let base = selectedSchemas.isEmpty ? tables : tables.filter { selectedSchemas.contains($0.schema) }
        guard !tableFilter.isEmpty else { return base }
        return base.filter { $0.id.localizedCaseInsensitiveContains(tableFilter) }
    }

    var effectiveOptions: PGDumpOptions {
        var o = options
        o.schemas = schemas.filter { selectedSchemas.contains($0) }
        let picked = tables.filter { selectedTables.contains($0) }
        o.tables = tableMode == .only ? picked : []
        o.excludeTables = tableMode == .except ? picked : []
        o.compression = compress && o.format.supportsCompression ? compressionLevel : nil
        return o
    }

    var blocker: String? {
        if !isPostgres { return nil }
        if tool == nil { return "pg_dump not found" }
        if tableMode != .all && selectedTables.isEmpty { return "Select at least one table" }
        if FileManager.default.fileExists(atPath: output.path) && options.format == .directory { return "The output folder already exists" }
        return nil
    }

    func start() {
        if !isPostgres {
            let config = connection, output = output
            runLocal {
                try await BackupEngine.sqliteBackup(config: config, to: output)
                return "Backed up to \(output.abbreviatedPath) (\(Fmt.bytes(diskSize(output))))"
            }
            return
        }
        guard let tool, blocker == nil else { return }
        let options = effectiveOptions, output = output
        runProcess(database: database, make: { target in
            BackupEngine.pgDump(tool: tool, target: target, options: options, output: output)
        }, onSuccess: {
            "Backup written to \(output.abbreviatedPath) (\(Fmt.bytes(diskSize(output))))"
        })
    }
}

/// pg_dump (PostgreSQL) or VACUUM INTO (SQLite) backup of one database.
public struct BackupView: View {
    @StateObject private var model: BackupModel
    let onClose: () -> Void

    public init(connection: ConnectionConfig, database: String?, onClose: @escaping () -> Void) {
        _model = StateObject(wrappedValue: BackupModel(connection: connection, database: database, secrets: nil))
        self.onClose = onClose
    }

    init(model: BackupModel, onClose: @escaping () -> Void) {
        _model = StateObject(wrappedValue: model)
        self.onClose = onClose
    }

    public var body: some View {
        TransferSheet("Back Up Database",
                      subtitle: model.isPostgres ? "\(model.connection.name) · \(model.database)" : model.connection.subtitle,
                      systemImage: "externaldrive.badge.timemachine", tint: model.connection.accentColor) {
            EnvironmentTag(environment: model.connection.environment, colorHex: model.connection.colorHex)
        } content: {
            if model.isPostgres {
                postgresOptions.disabled(model.running)
            } else {
                Banner(.info, "SQLite databases are copied with VACUUM INTO, a consistent online copy that is also defragmented.")
            }
            outputRow.disabled(model.running)
            if let warning = model.toolWarning(model.tool, name: "pg_dump"), model.loaded {
                Banner(model.tool == nil ? .error : .warning, warning)
            }
            if let error = model.infoError {
                Banner(.warning, "Could not read the server details: \(error)")
            }
            SheetSection("Log") {
                ProcessLogView(log: model.log)
                    .frame(minHeight: 90, maxHeight: .infinity)
            }
            if let message = model.resultMessage {
                Banner(message.0, message.1)
            }
        } footerLeading: {
            HStack(spacing: DS.Space.m) {
                ElapsedText(start: model.startedAt, end: model.endedAt)
                if let blocker = model.blocker, model.loaded, !model.running {
                    Text(blocker)
                }
            }
        } footer: {
            HStack(spacing: DS.Space.m) {
                if model.running {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction)
                } else {
                    if case .success? = model.resultMessage?.0 {
                        Button("Reveal in Finder") { Panels.reveal([model.output]) }
                    }
                    Button("Close", action: onClose).keyboardShortcut(.cancelAction)
                    Button("Back Up") { model.start() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.blocker != nil || !model.loaded)
                }
            }
        }
        .frame(minWidth: model.isPostgres ? 680 : 520, idealWidth: model.isPostgres ? 780 : 560, maxWidth: .infinity,
               minHeight: model.isPostgres ? 640 : 400, idealHeight: model.isPostgres ? 720 : 440, maxHeight: .infinity)
        .task { await model.load() }
    }

    private var postgresOptions: some View {
        HStack(alignment: .top, spacing: DS.Space.xl + DS.Space.xs) {
            SheetSection("Options") {
                Card {
                    Form {
                        Picker("pg_dump", selection: $model.tool) {
                            if model.tools.isEmpty { Text("Not found").tag(PGTool?.none) }
                            ForEach(model.tools) { Text($0.displayName).tag(PGTool?.some($0)) }
                        }
                        Picker("Format", selection: $model.options.format) {
                            ForEach(PGDumpOptions.Format.allCases) { Text($0.displayName).tag($0) }
                        }
                        .onChange(of: model.options.format) { _, _ in model.formatChanged() }
                        Picker("Content", selection: $model.options.content) {
                            ForEach(PGDumpOptions.Content.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Toggle("No owner", isOn: $model.options.noOwner)
                            .help("--no-owner")
                        Toggle("No privileges", isOn: $model.options.noPrivileges)
                            .help("--no-privileges")
                        Toggle("Clean (drop first)", isOn: $model.options.clean)
                            .disabled(model.options.format != .plain || model.options.content == .dataOnly)
                            .help("--clean --if-exists. Plain format only; for archives choose it at restore time")
                        LabeledContent("Compress") {
                            HStack(spacing: DS.Space.m) {
                                Toggle("", isOn: $model.compress).labelsHidden()
                                    .disabled(!model.options.format.supportsCompression)
                                Stepper("Level \(model.compressionLevel)", value: $model.compressionLevel, in: 0...9)
                                    .monospacedDigit()
                                    .fixedSize()
                                    .disabled(!model.compress || !model.options.format.supportsCompression)
                            }
                        }
                        .help("--compress")
                        if model.options.format == .directory {
                            LabeledContent("Parallel jobs") {
                                Stepper("\(model.options.jobs)", value: $model.options.jobs, in: 1...16).monospacedDigit().fixedSize()
                            }
                        }
                        if let v = model.serverVersion {
                            LabeledContent("Server") { Text("PostgreSQL \(v)").foregroundStyle(.secondary).lineLimit(1) }
                        }
                    }
                    .formStyle(.columns)
                }
            }
            .frame(width: 340)
            selection
        }
    }

    private var selection: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            SheetSection("Schemas", count: model.schemas.isEmpty ? nil : model.schemas.count) {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: DS.Space.xs) {
                            ForEach(model.schemas, id: \.self) { s in
                                Toggle(s, isOn: Binding(get: { model.selectedSchemas.contains(s) }, set: { on in
                                    if on { model.selectedSchemas.insert(s) } else { model.selectedSchemas.remove(s) }
                                }))
                                .toggleStyle(.button)
                                .controlSize(.small)
                            }
                        }
                    }
                    HintText(model.selectedSchemas.isEmpty ? "None selected: every schema is included." : "Only the selected schemas (-n).")
                }
            }
            SheetSection("Tables") {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    CompactSegmented(BackupModel.TableMode.allCases.map { (label: $0.rawValue, value: $0) }, selection: $model.tableMode)
                    if model.tableMode != .all {
                        TextField("Filter tables", text: $model.tableFilter).textFieldStyle(.roundedBorder)
                        List(model.filteredTables) { t in
                            Toggle(t.id, isOn: Binding(get: { model.selectedTables.contains(t) }, set: { on in
                                if on { model.selectedTables.insert(t) } else { model.selectedTables.remove(t) }
                            }))
                            .font(DS.Typo.callout)
                        }
                        .listStyle(.bordered)
                        .frame(minHeight: 90, maxHeight: 180)
                        HintText(model.tableMode == .only ? "\(model.selectedTables.count) tables included (-t)" : "\(model.selectedTables.count) tables excluded (--exclude-table)")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var outputRow: some View {
        SheetSection("Destination") {
            Card(padding: DS.Space.m + DS.Space.xxs) {
                HStack(spacing: DS.Space.m) {
                    Image(systemName: model.options.format == .directory ? "folder" : "doc")
                        .foregroundStyle(.secondary)
                    Text(model.output.abbreviatedPath)
                        .font(DS.Typo.callout)
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(model.output.path)
                    Spacer(minLength: DS.Space.m)
                    Button("Change…") { model.chooseOutput() }.controlSize(.small)
                }
            }
        }
    }
}

/// Process output waiting to reach the main actor.
final class PendingLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    func take() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let out = lines
        lines = []
        return out
    }
}
