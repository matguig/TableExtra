import AppKit
import MTPCore
import MTPUIKit
import SwiftUI

@MainActor
final class RestoreModel: ProcessTaskModel {
    @Published var file: URL?
    @Published var fileFormat: BackupFileFormat?
    @Published var targetDatabase: String
    @Published var options = PGRestoreOptions()
    @Published var restoreTools: [PGTool] = []
    @Published var psqlTools: [PGTool] = []
    @Published var tool: PGTool?
    @Published var confirmation = ""
    @Published var askConfirm = false
    @Published var loaded = false

    override init(connection: ConnectionConfig, database: String?, secrets: ConnectionSecrets?) {
        targetDatabase = database ?? connection.database
        super.init(connection: connection, database: database, secrets: secrets)
        options.noOwner = true
    }

    var isReadOnly: Bool { connection.safety == .readOnly }
    /// Production and staging need the database (or file) name typed before restoring.
    var requiresTypedConfirmation: Bool { connection.isProductionLike }
    var confirmationWord: String { isPostgres ? targetDatabase : (connection.filePath as NSString).lastPathComponent }
    var usesPgRestore: Bool { fileFormat?.usesPgRestore ?? true }
    var toolName: String { usesPgRestore ? "pg_restore" : "psql" }

    func load() async {
        guard isPostgres else { loaded = true; return }
        let (r, p) = await Task.detached { (PGToolLocator.candidates("pg_restore"), PGToolLocator.candidates("psql")) }.value
        restoreTools = r
        psqlTools = p
        await loadServerInfo()
        pickTool()
        loaded = true
    }

    func pickTool() {
        tool = PGToolLocator.preferred(toolName, serverMajor: serverMajor, among: usesPgRestore ? restoreTools : psqlTools)
    }

    func chooseFile() {
        guard let url = Panels.chooseFile(allowDirectories: isPostgres) else { return }
        file = url
        fileFormat = isPostgres ? BackupFileFormat.detect(url) : nil
        resultMessage = nil
        pickTool()
    }

    var blocker: String? {
        if isReadOnly { return "This connection is read-only" }
        guard file != nil else { return "Choose a backup file" }
        if isPostgres {
            if tool == nil { return "\(toolName) not found" }
            if targetDatabase.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter the target database" }
        }
        if requiresTypedConfirmation && confirmation != confirmationWord { return "Type \(confirmationWord) to confirm" }
        return nil
    }

    func start() {
        guard let file, blocker == nil else { return }
        if !isPostgres {
            let path = connection.filePath
            runLocal {
                let safety = try BackupEngine.sqliteRestore(from: file, over: path)
                return "Restored \((path as NSString).abbreviatingWithTildeInPath) from \(file.lastPathComponent)."
                    + (safety.map { " The previous file was kept at \($0.abbreviatedPath)." } ?? "")
            }
            return
        }
        guard let tool, let format = fileFormat else { return }
        let options = options, db = targetDatabase
        runProcess(database: db, make: { target in
            format.usesPgRestore
                ? BackupEngine.pgRestore(tool: tool, target: target, options: options, input: file)
                : BackupEngine.psql(tool: tool, target: target, options: options, input: file, format: format)
        }, onSuccess: {
            "Restored \(file.lastPathComponent) into \(db). Refresh the sidebar to see the changes."
        })
    }
}

/// pg_restore / psql (PostgreSQL) or file replacement (SQLite).
public struct RestoreView: View {
    @StateObject private var model: RestoreModel
    let onClose: () -> Void

    public init(connection: ConnectionConfig, database: String?, onClose: @escaping () -> Void) {
        _model = StateObject(wrappedValue: RestoreModel(connection: connection, database: database, secrets: nil))
        self.onClose = onClose
    }

    init(model: RestoreModel, onClose: @escaping () -> Void) {
        _model = StateObject(wrappedValue: model)
        self.onClose = onClose
    }

    public var body: some View {
        TransferSheet("Restore Database", subtitle: "\(model.connection.name) · \(model.connection.subtitle)",
                      systemImage: "arrow.counterclockwise", tint: model.connection.accentColor) {
            EnvironmentTag(environment: model.connection.environment, colorHex: model.connection.colorHex)
        } content: {
            if model.isReadOnly {
                Banner(.error, "\(model.connection.name) is read-only. Change its safety level to restore into it.")
                Spacer(minLength: 0)
            } else {
                fileRow.disabled(model.running)
                if model.isPostgres {
                    postgresOptions.disabled(model.running)
                    if let warning = model.toolWarning(model.tool, name: model.toolName), model.loaded {
                        Banner(model.tool == nil ? .error : .warning, warning)
                    }
                    if let error = model.infoError {
                        Banner(.warning, "Could not read the server details: \(error)")
                    }
                } else {
                    Banner(.info, "The SQLite file is replaced by the backup. A copy of the current file is kept in the Backups folder.")
                }
                if model.requiresTypedConfirmation {
                    confirmRow.disabled(model.running)
                }
                SheetSection("Log") {
                    ProcessLogView(log: model.log)
                        .frame(minHeight: 80, maxHeight: .infinity)
                }
            }
            if let message = model.resultMessage {
                Banner(message.0, message.1)
            }
        } footerLeading: {
            HStack(spacing: DS.Space.m) {
                ElapsedText(start: model.startedAt, end: model.endedAt)
                if let blocker = model.blocker, model.loaded, !model.running, !model.isReadOnly {
                    Text(blocker)
                }
            }
        } footer: {
            HStack(spacing: DS.Space.m) {
                if model.running {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction)
                } else {
                    Button("Close", action: onClose).keyboardShortcut(.cancelAction)
                    if !model.isReadOnly {
                        Button("Restore") {
                            if model.requiresTypedConfirmation { model.start() } else { model.askConfirm = true }
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.blocker != nil || !model.loaded)
                    }
                }
            }
        }
        .frame(minWidth: 600, idealWidth: 700, maxWidth: .infinity,
               minHeight: model.isReadOnly ? 240 : (model.isPostgres ? 640 : 420),
               idealHeight: model.isReadOnly ? 260 : (model.isPostgres ? 700 : 460), maxHeight: .infinity)
        .task { await model.load() }
        .confirmationDialog("Restore into \(model.isPostgres ? model.targetDatabase : model.confirmationWord)?", isPresented: $model.askConfirm) {
            Button("Restore", role: .destructive) { model.start() }
        } message: {
            Text("Existing objects may be overwritten. This cannot be undone.")
        }
    }

    private var fileRow: some View {
        SheetSection("Backup File") {
            Card(padding: DS.Space.m + DS.Space.xxs) {
                HStack(spacing: DS.Space.m + DS.Space.xxs) {
                    Image(systemName: model.fileFormat == .directory ? "folder" : "doc.zipper")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.file?.lastPathComponent ?? "No file chosen")
                            .font(DS.Typo.body.weight(model.file == nil ? .regular : .medium))
                            .foregroundStyle(model.file == nil ? .secondary : .primary)
                            .lineLimit(1).truncationMode(.middle)
                        if let file = model.file {
                            Text(fileDetail(file))
                                .font(DS.Typo.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .layoutPriority(1)
                    Spacer(minLength: DS.Space.m)
                    Button("Choose…") { model.chooseFile() }.controlSize(.small)
                }
            }
        }
    }

    private func fileDetail(_ file: URL) -> String {
        var parts = [file.deletingLastPathComponent().abbreviatedPath]
        if let f = model.fileFormat { parts.append("\(f.displayName) → \(f.usesPgRestore ? "pg_restore" : "psql")") }
        return parts.joined(separator: "  ·  ")
    }

    private var postgresOptions: some View {
        SheetSection("Options") {
            Card {
                Form {
                    TextField("Target database", text: $model.targetDatabase)
                        .frame(maxWidth: 280)
                    Picker(model.toolName, selection: $model.tool) {
                        let list = model.usesPgRestore ? model.restoreTools : model.psqlTools
                        if list.isEmpty { Text("Not found").tag(PGTool?.none) }
                        ForEach(list) { Text($0.displayName).tag(PGTool?.some($0)) }
                    }
                    .frame(maxWidth: 380)
                    if model.usesPgRestore {
                        Picker("Content", selection: $model.options.content) {
                            ForEach(PGDumpOptions.Content.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .fixedSize()
                        LabeledContent("Parallel jobs") {
                            Stepper("\(model.options.jobs)", value: $model.options.jobs, in: 1...16).monospacedDigit().fixedSize()
                        }
                        .disabled(model.options.singleTransaction || model.fileFormat == .tar)
                        LabeledContent("Options") {
                            Grid(alignment: .leading, horizontalSpacing: DS.Space.xl, verticalSpacing: DS.Space.s) {
                                GridRow {
                                    Toggle("Drop objects first", isOn: $model.options.clean)
                                        .disabled(model.options.content == .dataOnly)
                                        .help("--clean --if-exists")
                                    Toggle("Single transaction", isOn: $model.options.singleTransaction)
                                }
                                GridRow {
                                    Toggle("No owner", isOn: $model.options.noOwner).help("--no-owner")
                                    Toggle("No privileges", isOn: $model.options.noPrivileges).help("--no-privileges")
                                }
                                GridRow {
                                    Toggle("Stop at the first error", isOn: $model.options.stopOnError).help("--exit-on-error")
                                        .gridCellColumns(2)
                                }
                            }
                            .fixedSize()
                        }
                    } else {
                        LabeledContent("Options") {
                            VStack(alignment: .leading, spacing: DS.Space.s) {
                                Toggle("Single transaction", isOn: $model.options.singleTransaction)
                                Toggle("Stop at the first error", isOn: $model.options.stopOnError).help("ON_ERROR_STOP")
                            }
                            .fixedSize()
                        }
                    }
                }
                .formStyle(.columns)
            }
        }
    }

    private var confirmRow: some View {
        let red = NSColor.systemRed
        return HStack(spacing: DS.Space.l) {
            Image(systemName: "exclamationmark.shield.fill").foregroundStyle(Color(nsColor: red))
            Text("\(model.connection.environment.displayName) connection — type **\(model.confirmationWord)** to confirm.")
                .font(DS.Typo.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: DS.Space.m)
            TextField(model.confirmationWord, text: $model.confirmation)
                .textFieldStyle(.roundedBorder)
                .font(DS.Typo.mono)
                .frame(width: 200)
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.m)
        .background(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).fill(Color(nsColor: red.softFill()).opacity(0.7)))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).strokeBorder(Color(nsColor: red).opacity(0.3), lineWidth: 0.5))
    }
}
