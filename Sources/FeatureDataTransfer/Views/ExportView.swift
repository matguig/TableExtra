import AppKit
import MTPCore
import MTPUIKit
import SwiftUI

@MainActor
final class ExportModel: ObservableObject {
    enum Phase {
        case idle
        case running
        case done(files: [URL], rows: Int, duration: TimeInterval)
        case failed(String)
        case cancelled
    }

    let context: WorkspaceContext?
    let source: ExportSource

    @Published var format: ExportFormat = .csv
    @Published var options = ExportOptions()
    /// SQL INSERT target for in-memory results.
    @Published var sqlTableName: String
    @Published var phase: Phase = .idle
    @Published var progressText = ""
    @Published var fraction: Double?
    @Published var copied = false
    var task: Task<Void, Never>?

    init(context: WorkspaceContext?, source: ExportSource) {
        self.context = context
        self.source = source
        switch source {
        case .result(_, _, let table): sqlTableName = table ?? "my_table"
        case .tables: sqlTableName = ""
        }
    }

    var dialect: SQLDialect { context?.dialect ?? SQLDialect(kind: .postgres) }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    var result: QueryResult? {
        if case .result(let r, _, _) = source { return r }
        return nil
    }

    var tables: (schema: String, names: [String])? {
        if case .tables(let s, let n) = source { return (s, n) }
        return nil
    }

    var title: String {
        switch source {
        case .result(let r, let name, _): return "Export \(name)  ·  \(Fmt.count(Int64(r.rows.count))) rows, \(r.columns.count) columns"
        case .tables(let schema, let names):
            return names.count == 1 ? "Export table \(schema).\(names[0])" : "Export \(names.count) tables from \(schema)"
        }
    }

    /// Several tables in a non-SQL format go to one file each inside a folder.
    var writesFolder: Bool {
        guard let t = tables else { return false }
        return t.names.count > 1 && format != .sqlInsert
    }

    var suggestedFileName: String {
        switch source {
        case .result(_, let name, _): return "\(TableExporter.safeFileName(name)).\(format.fileExtension)"
        case .tables(let schema, let names):
            let base = names.count == 1 ? names[0] : "\(schema)-export"
            return "\(TableExporter.safeFileName(base)).\(format.fileExtension)"
        }
    }

    /// First rows rendered with the current settings (in-memory results only).
    var previewText: String {
        guard let r = result else { return "" }
        let sample = QueryResult(columns: r.columns, rows: Array(r.rows.prefix(12)))
        var text = DataExporter.render(sample, format: format, options: options, tableName: sqlTableName.isEmpty ? nil : sqlTableName, dialect: dialect)
        if r.rows.count > 12 { text += format == .json ? "\n…" : "…" }
        return text
    }

    func renderAll() -> String {
        guard let r = result else { return "" }
        return DataExporter.render(r, format: format, options: options, tableName: sqlTableName.isEmpty ? nil : sqlTableName, dialect: dialect)
    }

    func copyToClipboard() {
        Pasteboard.copy(renderAll())
        copied = true
        context?.showToast("Copied \(result?.rows.count ?? 0) rows as \(format.rawValue)")
    }

    func chooseDestinationAndExport() {
        let destination: URL?
        if writesFolder {
            destination = Panels.chooseFolder(prompt: "Export Here")
        } else {
            destination = FilePanels.chooseSaveURL(suggestedName: suggestedFileName, types: [format.contentType])
        }
        guard let destination else { return }
        export(to: destination)
    }

    func export(to destination: URL) {
        phase = .running
        fraction = nil
        progressText = "Starting…"
        let format = format, options = options
        if let r = result {
            let table = sqlTableName.isEmpty ? nil : sqlTableName
            let dialect = dialect
            task = Task {
                let start = Date()
                let outcome: Result<Void, Error> = await Task.detached {
                    do {
                        var data = Data()
                        if options.utf8BOM && (format == .csv || format == .tsv) { data.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
                        data.append(contentsOf: DataExporter.render(r, format: format, options: options, tableName: table, dialect: dialect).utf8)
                        try data.write(to: destination, options: .atomic)
                        return .success(())
                    } catch {
                        return .failure(error)
                    }
                }.value
                switch outcome {
                case .success: self.phase = .done(files: [destination], rows: r.rows.count, duration: Date().timeIntervalSince(start))
                case .failure(let e): self.phase = .failed(e.localizedDescription)
                }
            }
            return
        }

        guard let t = tables, let context else {
            phase = .failed("Exporting tables needs an open connection.")
            return
        }
        let client = context.makeClient(label: "export")
        let exporter = TableExporter(client: client)
        task = Task {
            defer { client.close() }
            do {
                let r = try await exporter.export(schema: t.schema, tables: t.names, format: format, options: options, destination: destination) { p in
                    Task { @MainActor in self.apply(p) }
                }
                self.phase = .done(files: r.files, rows: r.rows, duration: r.duration)
            } catch is CancellationError {
                self.phase = .cancelled
            } catch {
                self.phase = .failed((error as? DatabaseError)?.fullMessage ?? error.localizedDescription)
            }
        }
    }

    private func apply(_ p: TableExportProgress) {
        guard isRunning else { return }
        fraction = p.fraction
        let table = p.tableCount > 1 ? "\(p.table) (\(min(p.tableIndex + 1, p.tableCount)) of \(p.tableCount))" : p.table
        progressText = "\(table) — \(Fmt.count(Int64(p.rowsInTable))) rows · \(Fmt.count(Int64(p.totalRows))) total"
    }

    func cancel() {
        task?.cancel()
    }
}

/// Export sheet: format, options, destination, progress.
public struct ExportView: View {
    @StateObject private var model: ExportModel
    let onClose: () -> Void

    public init(context: WorkspaceContext?, source: ExportSource, onClose: @escaping () -> Void) {
        _model = StateObject(wrappedValue: ExportModel(context: context, source: source))
        self.onClose = onClose
    }

    init(model: ExportModel, onClose: @escaping () -> Void) {
        _model = StateObject(wrappedValue: model)
        self.onClose = onClose
    }

    public var body: some View {
        TransferSheet("Export Data", subtitle: model.title, systemImage: "square.and.arrow.up",
                      tint: model.context?.connection.accentColor ?? .accentColor) {
            if let c = model.context?.connection {
                EnvironmentTag(environment: c.environment, colorHex: c.colorHex)
            }
        } content: {
            HStack(alignment: .top, spacing: DS.Space.xl + DS.Space.xs) {
                settings
                    .frame(width: model.result != nil ? 300 : nil, alignment: .topLeading)
                    .frame(maxWidth: model.result != nil ? nil : .infinity, alignment: .topLeading)
                if model.result != nil {
                    preview
                }
            }
            .disabled(model.isRunning)
            .frame(maxHeight: .infinity, alignment: .top)
            status
        } footerLeading: {
            if case .done(let files, _, _) = model.phase {
                Button("Reveal in Finder") { Panels.reveal(files) }
            }
        } footer: {
            HStack(spacing: DS.Space.m) {
                if model.isRunning {
                    Button("Cancel") { model.cancel() }
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button("Close", action: onClose)
                        .keyboardShortcut(.cancelAction)
                    if model.result != nil {
                        Button(model.copied ? "Copied" : "Copy to Clipboard") { model.copyToClipboard() }
                    }
                    Button(model.writesFolder ? "Export to Folder…" : "Export…") { model.chooseDestinationAndExport() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(minWidth: model.result != nil ? 720 : 460, idealWidth: model.result != nil ? 860 : 520, maxWidth: .infinity,
               minHeight: model.result != nil ? 460 : 400, idealHeight: model.result != nil ? 540 : 440, maxHeight: .infinity)
        .onChange(of: model.format) { _, _ in model.copied = false }
        .onChange(of: model.options) { _, _ in model.copied = false }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            SheetSection("Format") {
                Card {
                    Form {
                        Picker("Format", selection: $model.format) {
                            ForEach(ExportFormat.allCases) { Text($0.rawValue).tag($0) }
                        }
                        formatOptions
                    }
                    .formStyle(.columns)
                }
            }
            if model.writesFolder {
                HintText("One .\(model.format.fileExtension) file per table in the folder you choose.")
            } else if model.tables != nil {
                HintText("Rows are streamed from the server \(Fmt.count(Int64(TableExporter.pageSize))) at a time in primary-key order.")
            }
        }
    }

    @ViewBuilder
    private var formatOptions: some View {
        switch model.format {
        case .csv:
            Picker("Delimiter", selection: $model.options.delimiter) {
                ForEach(ExportOptions.delimiterChoices, id: \.value) { Text($0.label).tag($0.value) }
            }
            delimitedOptions
        case .tsv:
            delimitedOptions
        case .json:
            Toggle("Pretty-print", isOn: $model.options.prettyJSON)
            LabeledContent("") {
                HintText("Numbers and booleans are typed, json/jsonb columns embedded, NULL → null.")
            }
        case .jsonLines:
            LabeledContent("") { HintText("One compact JSON object per line.") }
        case .sqlInsert:
            if model.result != nil {
                TextField("Table name", text: $model.sqlTableName)
            }
            LabeledContent("Rows per INSERT") {
                Stepper(value: $model.options.sqlBatchSize, in: 1...10_000, step: model.options.sqlBatchSize < 10 ? 1 : 50) {
                    Text("\(model.options.sqlBatchSize)").monospacedDigit()
                }
                .fixedSize()
            }
            if model.tables != nil {
                Toggle("Include CREATE TABLE", isOn: $model.options.includeCreateTable)
                Toggle("DROP TABLE IF EXISTS first", isOn: $model.options.includeDropTable)
                    .disabled(!model.options.includeCreateTable)
            }
        case .markdown:
            Picker("NULL as", selection: $model.options.nullStyle) {
                ForEach(ExportOptions.NullStyle.allCases) { Text($0.rawValue).tag($0) }
            }
        }
    }

    @ViewBuilder
    private var delimitedOptions: some View {
        Toggle("Header row", isOn: $model.options.includeHeader)
        Picker("NULL as", selection: $model.options.nullStyle) {
            ForEach(ExportOptions.NullStyle.allCases) { Text($0 == .empty ? "Empty field" : "NULL").tag($0) }
        }
        Picker("Line endings", selection: $model.options.lineEnding) {
            ForEach(ExportOptions.LineEnding.allCases) { Text($0.rawValue).tag($0) }
        }
        Toggle("UTF-8 BOM (Excel)", isOn: $model.options.utf8BOM)
            .help("Writes a UTF-8 byte order mark so Excel detects the encoding")
    }

    private var preview: some View {
        SheetSection("Preview") {
            if let r = model.result {
                Text("first \(min(12, r.rows.count)) of \(Fmt.count(Int64(r.rows.count))) rows")
                    .font(DS.Typo.caption).foregroundStyle(.tertiary).monospacedDigit()
            }
        } content: {
            InsetBox {
                ScrollView([.horizontal, .vertical]) {
                    Text(model.previewText)
                        .font(DS.Typo.monoSmall)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .fixedSize()
                        .padding(DS.Space.m + DS.Space.xxs)
                }
                .defaultScrollAnchor(.topLeading)
            }
            .frame(minHeight: 180, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var status: some View {
        switch model.phase {
        case .idle:
            EmptyView()
        case .running:
            VStack(alignment: .leading, spacing: DS.Space.s) {
                if let f = model.fraction {
                    ProgressView(value: f)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                Text(model.progressText).font(DS.Typo.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
        case .done(let files, let rows, let duration):
            Banner(.success, "Exported \(Fmt.count(Int64(rows))) rows in \(Fmt.duration(duration)) to "
                + (files.count == 1 ? files[0].abbreviatedPath : "\(files.count) files in \(files.first?.deletingLastPathComponent().abbreviatedPath ?? "")"))
        case .failed(let message):
            Banner(.error, message)
        case .cancelled:
            Banner(.warning, "Export cancelled; partial files were removed.")
        }
    }
}
