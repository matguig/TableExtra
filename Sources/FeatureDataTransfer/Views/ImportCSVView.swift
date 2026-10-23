import AppKit
import MTPCore
import MTPUIKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ImportModel: ObservableObject {
    enum Target: String, CaseIterable, Identifiable {
        case existing = "Existing table"
        case new = "New table"
        var id: String { rawValue }
    }

    let context: WorkspaceContext
    let schema: String

    @Published var url: URL?
    @Published var kind: ImportFileKind = .delimited
    @Published var settings = ImportFileSettings()
    @Published var preview: ImportFilePreview?
    @Published var loadError: String?
    @Published var loading = false

    @Published var target: Target
    @Published var tables: [String] = []
    @Published var existingTable: String
    @Published var existingColumns: [ColumnDef] = []
    @Published var newTableName = ""
    @Published var columns: [ImportColumn] = []

    @Published var truncateFirst = false
    @Published var batchSize = 500
    @Published var errorPolicy: ImportPlan.ErrorPolicy = .stop
    @Published var emptyAsNull = true

    @Published var running = false
    @Published var progress: ImportProgress?
    @Published var report: ImportReport?
    var task: Task<Void, Never>?

    init(context: WorkspaceContext, schema: String, table: String?) {
        self.context = context
        self.schema = schema
        self.existingTable = table ?? ""
        self.target = table == nil ? .new : .existing
    }

    var dialect: SQLDialect { context.dialect }
    var tableName: String { target == .existing ? existingTable : newTableName }

    func loadTables() async {
        let objects = (try? await context.introspector.objects(in: schema)) ?? []
        tables = objects.filter { $0.kind == .table }.map(\.name).sorted()
        if target == .existing, !existingTable.isEmpty { await loadExistingColumns() }
    }

    func chooseFile() {
        let types: [UTType] = [.commaSeparatedText, .tabSeparatedText, .json, .plainText, .text, .data]
        guard let url = FilePanels.open(types: types).first else { return }
        Task { await load(url) }
    }

    func load(_ url: URL) async {
        self.url = url
        loading = true
        loadError = nil
        report = nil
        let kind = ImportFileLoader.kind(of: url)
        do {
            let (settings, preview) = try await Task.detached { () throws -> (ImportFileSettings, ImportFilePreview) in
                let s = kind == .delimited ? try ImportFileLoader.sniff(url) : ImportFileSettings()
                return (s, try ImportFileLoader.preview(url, kind: kind, settings: s))
            }.value
            self.kind = kind
            self.settings = settings
            apply(preview)
            if newTableName.isEmpty { newTableName = ImportMapping.tableName(for: url) }
        } catch {
            loadError = error.localizedDescription
            preview = nil
        }
        loading = false
    }

    /// Re-reads the file after the delimiter, encoding or header setting changed.
    func reload() async {
        guard let url else { return }
        let kind = kind, settings = settings
        loading = true
        do {
            let p = try await Task.detached { try ImportFileLoader.preview(url, kind: kind, settings: settings) }.value
            apply(p)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        loading = false
    }

    private func apply(_ p: ImportFilePreview) {
        preview = p
        remap()
    }

    func remap() {
        guard let p = preview else { columns = []; return }
        switch target {
        case .existing: columns = ImportMapping.mapByName(preview: p, target: existingColumns)
        case .new: columns = ImportMapping.newTableColumns(preview: p, dialect: dialect)
        }
    }

    func loadExistingColumns() async {
        guard !existingTable.isEmpty else { existingColumns = []; remap(); return }
        let details = try? await context.introspector.tableDetails(schema: schema, name: existingTable)
        existingColumns = details?.columns ?? []
        remap()
    }

    func setTarget(_ index: Int, column name: String) {
        guard index < columns.count else { return }
        if name.isEmpty {
            columns[index].target = ""
            columns[index].include = false
            return
        }
        guard let c = existingColumns.first(where: { $0.name == name }) else { return }
        columns[index].target = c.name
        columns[index].sqlType = c.dataType
        columns[index].targetKind = c.kind
        columns[index].include = true
    }

    func setType(_ index: Int, _ type: InferredType) {
        guard index < columns.count else { return }
        columns[index].sqlType = type.sqlType(for: dialect)
        columns[index].targetKind = type.valueKind
    }

    func inferredChoice(for column: ImportColumn) -> InferredType {
        InferredType.choices(for: dialect).first { $0.sqlType(for: dialect) == column.sqlType } ?? .text
    }

    var plan: ImportPlan {
        ImportPlan(schema: schema, table: tableName, createTable: target == .new, columns: columns, truncateFirst: truncateFirst && target == .existing,
                   batchSize: batchSize, errorPolicy: errorPolicy, emptyAsNull: emptyAsNull)
    }

    /// Why Import is disabled, if it is.
    var blocker: String? {
        guard preview != nil else { return "Choose a file" }
        if tableName.trimmingCharacters(in: .whitespaces).isEmpty { return target == .existing ? "Choose a table" : "Name the new table" }
        if target == .new && tables.contains(newTableName) { return "A table named \(newTableName) already exists" }
        if plan.included.isEmpty { return "Map at least one column" }
        let targets = plan.included.map(\.target)
        if Set(targets).count != targets.count { return "Two file columns go to the same table column" }
        return nil
    }

    var rowCountLabel: String {
        guard let p = preview else { return "" }
        return p.isComplete ? "\(Fmt.count(Int64(p.rows.count))) rows" : "\(Fmt.count(Int64(p.rows.count)))+ rows (\(Fmt.bytes(p.fileSize)))"
    }

    func runImport() {
        guard let url, let preview, blocker == nil else { return }
        let plan = plan
        let kind = kind, settings = settings
        let sql = plan.previewSQL(dialect, rowCount: preview.isComplete ? preview.rows.count : nil)
        let summary = "Import \(rowCountLabel) from \(url.lastPathComponent) into \(schema).\(plan.table)"
        report = nil
        task = Task {
            guard await context.confirmWrite(sql: sql, summary: summary) else { return }
            running = true
            progress = ImportProgress(rowsRead: 0, inserted: 0, skipped: 0, fraction: 0)
            let client = context.makeClient(label: "import")
            let work = Task.detached { () -> ImportReport in
                do {
                    let source = try ImportFileLoader.makeSource(url, kind: kind, settings: settings)
                    return await DataImporter.run(plan: plan, source: source, client: client) { p in
                        Task { @MainActor in self.progress = p }
                    }
                } catch {
                    var r = ImportReport()
                    r.failure = error.localizedDescription
                    return r
                }
            }
            let r = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            client.close()
            report = r
            running = false
            if r.committed {
                context.refreshSidebar()
                context.showToast("Imported \(Fmt.count(Int64(r.inserted))) rows into \(plan.table)")
                if plan.createTable { tables = (tables + [plan.table]).sorted() }
            }
        }
    }

    func cancel() { task?.cancel() }
}

/// CSV / JSON import into an existing or new table.
public struct ImportCSVView: View {
    @StateObject private var model: ImportModel
    let onClose: () -> Void

    public init(context: WorkspaceContext, schema: String, table: String?, onClose: @escaping () -> Void) {
        _model = StateObject(wrappedValue: ImportModel(context: context, schema: schema, table: table))
        self.onClose = onClose
    }

    init(model: ImportModel, onClose: @escaping () -> Void) {
        _model = StateObject(wrappedValue: model)
        self.onClose = onClose
    }

    public var body: some View {
        TransferSheet("Import Data", subtitle: subtitle,
                      systemImage: "square.and.arrow.down", tint: model.context.connection.accentColor) {
            EnvironmentTag(environment: model.context.connection.environment, colorHex: model.context.connection.colorHex)
        } content: {
            if model.url != nil { fileRow }
            if let error = model.loadError {
                Banner(.error, error)
            }
            if let preview = model.preview {
                SheetSection("Preview", count: nil) {
                    Text(model.rowCountLabel).font(DS.Typo.caption).foregroundStyle(.tertiary).monospacedDigit()
                } content: {
                    ResultTableView(result: preview.result)
                        .frame(minHeight: 90, idealHeight: 130, maxHeight: 130)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).strokeBorder(DS.Palette.separator, lineWidth: 0.5))
                }
                SheetSection("Destination") { targetRow }
                SheetSection("Columns", count: model.columns.count) {
                    if let r = model.report, !r.errors.isEmpty {
                        Tag("\(r.errors.count) \(r.errors.count == 1 ? "ERROR" : "ERRORS")", color: .systemRed, systemImage: "exclamationmark.triangle.fill")
                    }
                } content: {
                    mappingTable
                }
                optionsRow
            } else if model.loadError == nil {
                emptyState
            }
            statusArea
        } footerLeading: {
            if model.preview != nil, !model.running {
                if let blocker = model.blocker {
                    Text(blocker)
                } else {
                    Text("\(model.columns.filter(\.include).count) of \(model.columns.count) columns will be imported").monospacedDigit()
                }
            }
        } footer: {
            HStack(spacing: DS.Space.m) {
                if model.running {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction)
                } else {
                    Button("Close", action: onClose).keyboardShortcut(.cancelAction)
                    if model.report?.committed == true {
                        Button("Open Table") {
                            model.context.openTable(schema: model.schema, name: model.tableName)
                            onClose()
                        }
                    }
                    Button("Import") { model.runImport() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.blocker != nil)
                }
            }
        }
        .frame(minWidth: 720, idealWidth: 860, maxWidth: .infinity,
               minHeight: model.preview == nil ? 380 : (model.report == nil ? 680 : 740), idealHeight: model.preview == nil ? 420 : 800, maxHeight: .infinity)
        .task { await model.loadTables() }
    }

    /// "file.csv → schema.table" once a file is chosen.
    private var subtitle: String {
        guard let url = model.url else { return "Into \(model.schema) on \(model.context.connection.name)" }
        let table = model.tableName.isEmpty ? "…" : model.tableName
        return "\(url.lastPathComponent)  →  \(model.schema).\(table)"
    }

    private var emptyState: some View {
        EmptyState("Choose a file to import", systemImage: "doc.badge.plus",
                   message: "CSV, TSV or JSON (array of objects or JSON Lines). Delimiter, header and encoding (UTF-8, UTF-16, Latin-1) are detected automatically.") {
            Button("Choose File…") { model.chooseFile() }
        }
        .background(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
            .strokeBorder(DS.Palette.separator, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
    }

    private var fileRow: some View {
        SheetSection("Source File") {
            Card(padding: DS.Space.m + DS.Space.xxs) {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    if let url = model.url {
                        HStack(spacing: DS.Space.m + DS.Space.xxs) {
                            Image(systemName: model.kind == .json ? "curlybraces" : "tablecells")
                                .font(.system(size: 15))
                                .foregroundStyle(.secondary)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(url.lastPathComponent).font(DS.Typo.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                                Text(url.deletingLastPathComponent().abbreviatedPath)
                                    .font(DS.Typo.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer(minLength: DS.Space.m)
                            Tag(model.kind == .json ? "JSON" : "DELIMITED", color: .systemGray)
                            if model.loading { ProgressView().controlSize(.small) }
                            Button("Change…") { model.chooseFile() }.controlSize(.small)
                        }
                        if model.kind == .delimited {
                            Divider()
                            HStack(spacing: DS.Space.l) {
                                Picker("Delimiter", selection: delimiterBinding) {
                                    Text("Comma").tag(UInt8(ascii: ","))
                                    Text("Semicolon").tag(UInt8(ascii: ";"))
                                    Text("Tab").tag(UInt8(ascii: "\t"))
                                    Text("Pipe").tag(UInt8(ascii: "|"))
                                }
                                .fixedSize()
                                Picker("Encoding", selection: encodingBinding) {
                                    ForEach(TextFileEncoding.allCases) { Text($0.rawValue).tag($0) }
                                }
                                .fixedSize()
                                Toggle("First row is a header", isOn: headerBinding)
                                    .fixedSize()
                                Spacer(minLength: 0)
                            }
                            .controlSize(.small)
                            .font(DS.Typo.callout)
                        }
                    }
                }
            }
        }
        .disabled(model.running)
    }

    private var delimiterBinding: Binding<UInt8> {
        Binding(get: { model.settings.delimiter }, set: { model.settings.delimiter = $0; Task { await model.reload() } })
    }

    private var encodingBinding: Binding<TextFileEncoding> {
        Binding(get: { model.settings.encoding.encoding }, set: { e in
            let bom = e == model.settings.encoding.encoding ? model.settings.encoding.bomLength : 0
            model.settings.encoding = DetectedEncoding(encoding: e, bomLength: bom)
            Task { await model.reload() }
        })
    }

    private var headerBinding: Binding<Bool> {
        Binding(get: { model.settings.hasHeader }, set: { model.settings.hasHeader = $0; Task { await model.reload() } })
    }

    private var targetRow: some View {
        HStack(spacing: DS.Space.l) {
            CompactSegmented(ImportModel.Target.allCases.map { (label: $0.rawValue, value: $0) }, selection: $model.target)
                .onChange(of: model.target) { _, _ in
                    Task { model.target == .existing ? await model.loadExistingColumns() : model.remap() }
                }
            switch model.target {
            case .existing:
                Picker("Table", selection: $model.existingTable) {
                    Text("Choose…").tag("")
                    ForEach(model.tables, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: 280)
                .onChange(of: model.existingTable) { _, _ in Task { await model.loadExistingColumns() } }
            case .new:
                HStack(spacing: DS.Space.xs) {
                    Text("\(model.schema).").font(DS.Typo.mono).foregroundStyle(.secondary)
                    TextField("table_name", text: $model.newTableName)
                        .textFieldStyle(.roundedBorder)
                        .font(DS.Typo.mono)
                        .frame(maxWidth: 260)
                }
            }
            Spacer(minLength: 0)
        }
        .disabled(model.running)
    }

    private var mappingTable: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.m) {
                Text("").frame(width: 24, alignment: .leading)
                Text("From file").frame(width: 170, alignment: .leading)
                Text("").frame(width: 14)
                Text(model.target == .existing ? "To \(model.existingTable.isEmpty ? "table" : model.existingTable)" : "To new column")
                    .lineLimit(1).frame(width: 190, alignment: .leading)
                Text("Type").frame(width: 110, alignment: .leading)
                Text("Data preview").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(DS.Typo.eyebrow)
            .tracking(0.4)
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .padding(.horizontal, DS.Space.m + DS.Space.xxs)
            .frame(height: 26)
            .background(DS.Palette.bar)
            Rectangle().fill(DS.Palette.separator).frame(height: 0.5)
            ScrollView { mappingRows }
        }
        .frame(minHeight: 120, maxHeight: .infinity)
        .background(DS.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).strokeBorder(DS.Palette.separator, lineWidth: 0.5))
        .disabled(model.running)
    }

    private var mappingRows: some View {
        VStack(spacing: 0) {
            ForEach(model.columns.indices, id: \.self) { i in
                mappingRow(i)
                    .padding(.horizontal, DS.Space.m + DS.Space.xxs)
                    .frame(minHeight: 30)
                    .background(i % 2 == 1 ? Color.primary.opacity(0.025) : .clear)
            }
        }
    }

    /// First sampled values of a file column ("a@x.io, b@x.io").
    private func sample(_ column: ImportColumn) -> String {
        guard let rows = model.preview?.rows else { return "" }
        let values = rows.prefix(5).compactMap { r -> String? in
            column.sourceIndex < r.values.count ? r.values[column.sourceIndex] : nil
        }
        return values.joined(separator: ", ")
    }

    private func typeIcon(_ t: InferredType) -> String {
        switch t {
        case .integer, .bigint, .numeric: return "number"
        case .boolean: return "checkmark.square"
        case .date: return "calendar"
        case .timestamp, .timestamptz: return "clock"
        case .uuid: return "key"
        case .json: return "curlybraces"
        case .text: return "textformat"
        }
    }

    @ViewBuilder
    private func mappingRow(_ i: Int) -> some View {
        let column = model.columns[i]
        HStack(spacing: DS.Space.m) {
            Toggle("", isOn: Binding(get: { model.columns[i].include }, set: { model.columns[i].include = $0 }))
                .labelsHidden()
                .disabled(model.target == .existing && column.target.isEmpty)
                .frame(width: 24, alignment: .leading)
            HStack(spacing: DS.Space.s) {
                Image(systemName: typeIcon(column.inferred))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                    .help("Detected: \(column.inferred.rawValue)")
                Text(column.sourceName).font(DS.Typo.callout).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(column.include ? .primary : .secondary)
            }
            .frame(width: 170, alignment: .leading)
            Image(systemName: "arrow.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(column.include ? .secondary : .quaternary)
                .frame(width: 14)
            switch model.target {
            case .existing:
                Picker("", selection: Binding(get: { model.columns[i].target }, set: { model.setTarget(i, column: $0) })) {
                    Text("— skip —").tag("")
                    ForEach(model.existingColumns) { Text($0.name).tag($0.name) }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 190, alignment: .leading)
                HStack(spacing: DS.Space.xs) {
                    Text(column.sqlType).font(DS.Typo.monoSmall).foregroundStyle(.secondary).lineLimit(1)
                    if column.include && !TypeInference.isCompatible(column.inferred, with: column.targetKind) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            .help("Sampled values look like \(column.inferred.rawValue); some rows may be rejected")
                    }
                }
                .frame(width: 110, alignment: .leading)
            case .new:
                TextField("", text: Binding(get: { model.columns[i].target }, set: { model.columns[i].target = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .font(DS.Typo.mono)
                    .controlSize(.small)
                    .frame(width: 190)
                Picker("", selection: Binding(get: { model.inferredChoice(for: model.columns[i]) }, set: { model.setType(i, $0) })) {
                    ForEach(InferredType.choices(for: model.dialect)) { Text($0.sqlType(for: model.dialect)).tag($0) }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 110, alignment: .leading)
            }
            Text(sample(column))
                .font(DS.Typo.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var optionsRow: some View {
        SheetSection("Options") {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DS.Space.xl) { optionControls }
                VStack(alignment: .leading, spacing: DS.Space.s) { optionControls }
            }
            .font(DS.Typo.callout)
        }
        .disabled(model.running)
    }

    @ViewBuilder
    private var optionControls: some View {
        if model.target == .existing {
            Toggle("Truncate table first", isOn: $model.truncateFirst).fixedSize()
        }
        Toggle("Empty → NULL", isOn: $model.emptyAsNull)
            .fixedSize()
            .help("Unquoted empty fields become NULL; non-text columns always get NULL for empty values")
        Stepper("Batch of \(model.batchSize) rows", value: $model.batchSize, in: 50...10_000, step: 50)
            .monospacedDigit()
            .fixedSize()
        Picker("On error", selection: $model.errorPolicy) {
            ForEach(ImportPlan.ErrorPolicy.allCases) { Text($0.rawValue).tag($0) }
        }
        .fixedSize()
    }

    @ViewBuilder
    private var statusArea: some View {
        if model.running, let p = model.progress {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: p.fraction)
                Text("\(Fmt.count(Int64(p.rowsRead))) rows read · \(Fmt.count(Int64(p.inserted))) inserted"
                     + (p.skipped > 0 ? " · \(Fmt.count(Int64(p.skipped))) skipped" : ""))
                    .font(DS.Typo.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        } else if let r = model.report {
            reportView(r)
        }
    }

    @ViewBuilder
    private func reportView(_ r: ImportReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if r.cancelled {
                Banner(.warning, "Import cancelled. Nothing was written (the transaction was rolled back).")
            } else if let failure = r.failure {
                Banner(.error, "Import failed and was rolled back. \(failure)")
            } else {
                Banner(r.skipped > 0 ? .warning : .success,
                       "Imported \(Fmt.count(Int64(r.inserted))) rows in \(Fmt.duration(r.duration))"
                           + (r.skipped > 0 ? "; skipped \(Fmt.count(Int64(r.skipped))) bad rows." : "."))
            }
            if !r.errors.isEmpty && r.failure == nil {
                if r.errors.count > 4 {
                    ScrollView { errorLines(r) }.frame(maxHeight: 80)
                } else {
                    errorLines(r)
                }
            }
        }
    }

    private func errorLines(_ r: ImportReport) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(r.errors.prefix(200)) { e in
                Text("Line \(e.line): \(e.message)").font(DS.Typo.monoSmall).foregroundStyle(.secondary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

}
