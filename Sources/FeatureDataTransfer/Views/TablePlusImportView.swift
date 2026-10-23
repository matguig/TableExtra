import AppKit
import MTPCore
import MTPUIKit
import SwiftUI

@MainActor
final class TablePlusImportModel: ObservableObject {
    let importer: TablePlusImporter
    let store: ConnectionStore
    let history: HistoryStore

    @Published var preview: TablePlusImporter.Preview?
    @Published var error: String?
    @Published var selected: Set<UUID> = []
    @Published var importPasswords = true
    @Published var importHistory = true
    @Published var historyCounts: [String: Int] = [:]
    @Published var running = false
    @Published var summary: TablePlusImportSummary?
    @Published var loaded = false

    init(importer: TablePlusImporter = TablePlusImporter(), store: ConnectionStore = .shared, history: HistoryStore = .shared) {
        self.importer = importer
        self.store = store
        self.history = history
    }

    var isAvailable: Bool { importer.isAvailable }

    func load() {
        defer { loaded = true }
        guard importer.isAvailable else { return }
        do {
            let p = try importer.preview(existing: store.connections)
            preview = p
            selected = Set(p.connections.map(\.id))
            historyCounts = TablePlusMigration.historyCounts(in: importer.dataDirectory)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func groupName(_ c: ConnectionConfig) -> String? {
        guard let gid = c.groupID else { return nil }
        return preview?.groups.first { $0.id == gid }?.name
    }

    var selectedHistoryFiles: Int {
        (preview?.connections ?? []).filter { selected.contains($0.id) }.reduce(0) { $0 + (historyCounts[$1.tablePlusID ?? ""] ?? 0) }
    }

    func toggleAll() {
        guard let p = preview else { return }
        selected = selected.count == p.connections.count ? [] : Set(p.connections.map(\.id))
    }

    func runImport() {
        guard let preview, !selected.isEmpty else { return }
        running = true
        let importer = importer, store = store, history = history
        let selected = selected, passwords = importPasswords, withHistory = importHistory
        Task {
            // Keychain prompts block the calling thread; keep them off the main actor.
            let s = await Task.detached {
                TablePlusMigration.run(importer: importer, preview: preview, selected: selected, importPasswords: passwords,
                                       importHistory: withHistory, store: store, history: history)
            }.value
            summary = s
            running = false
        }
    }
}

/// Import connections, passwords and history from TablePlus.
public struct TablePlusImportView: View {
    @StateObject private var model: TablePlusImportModel
    let onClose: () -> Void

    public init(onClose: @escaping () -> Void) {
        _model = StateObject(wrappedValue: TablePlusImportModel())
        self.onClose = onClose
    }

    /// Reads another TablePlus data folder (tests, or a copy from another Mac) into the given stores.
    public init(dataDirectory: URL, store: ConnectionStore = .shared, history: HistoryStore = .shared, onClose: @escaping () -> Void) {
        _model = StateObject(wrappedValue: TablePlusImportModel(importer: TablePlusImporter(dataDirectory: dataDirectory), store: store, history: history))
        self.onClose = onClose
    }

    init(model: TablePlusImportModel, onClose: @escaping () -> Void) {
        _model = StateObject(wrappedValue: model)
        self.onClose = onClose
    }

    public var body: some View {
        TransferSheet("Import from TablePlus", subtitle: model.importer.dataDirectory.abbreviatedPath, systemImage: "arrow.down.doc") {
            content
        } footerLeading: {
            if model.running {
                HStack(spacing: DS.Space.s) {
                    ProgressView().controlSize(.small)
                    Text("Importing…")
                }
            }
        } footer: {
            HStack(spacing: DS.Space.m) {
                if model.running {
                    EmptyView()
                } else if model.summary != nil || !model.isAvailable || model.preview?.connections.isEmpty != false {
                    Button("Done", action: onClose).keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                    Button("Import \(model.selected.count) Connections") { model.runImport() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.selected.isEmpty)
                }
            }
        }
        .frame(minWidth: 600, idealWidth: 720, maxWidth: .infinity, minHeight: 460, idealHeight: 580, maxHeight: .infinity)
        .onAppear { if !model.loaded { model.load() } }
    }

    @ViewBuilder
    private var content: some View {
        if !model.loaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !model.isAvailable {
            EmptyState("TablePlus data was not found", systemImage: "tray",
                       message: "TableExtra looks for Connections.plist in \(model.importer.dataDirectory.abbreviatedPath). "
                           + "Open TablePlus once on this Mac, or add your connections manually.")
        } else if let error = model.error {
            Banner(.error, "Could not read TablePlus data: \(error)")
            Spacer(minLength: 0)
        } else if let summary = model.summary {
            summaryView(summary)
        } else if let preview = model.preview {
            if preview.connections.isEmpty {
                EmptyState("Nothing new to import", systemImage: "checkmark.circle",
                           message: "Every supported TablePlus connection is already imported.")
            } else {
                connectionList(preview)
            }
            if !preview.skipped.isEmpty {
                HintText("Skipped (driver not supported yet): " + preview.skipped.map { "\($0.name) (\($0.driver))" }.joined(separator: ", "))
                    .lineLimit(3)
            }
            if !preview.connections.isEmpty {
                SheetSection("Also Import") {
                    Card(padding: DS.Space.m + DS.Space.xxs) {
                        VStack(alignment: .leading, spacing: DS.Space.s) {
                            Toggle(isOn: $model.importPasswords) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Passwords from Keychain")
                                    Text("macOS asks for permission once per item").font(DS.Typo.caption).foregroundStyle(.secondary)
                                }
                            }
                            Toggle(isOn: $model.importHistory) {
                                HStack(spacing: DS.Space.s) {
                                    Text("Query history")
                                    Text("\(Fmt.count(Int64(model.selectedHistoryFiles))) files").font(DS.Typo.caption).foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                            .disabled(model.selectedHistoryFiles == 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .disabled(model.running)
            }
        }
    }

    private func connectionList(_ preview: TablePlusImporter.Preview) -> some View {
        SheetSection("Connections", count: preview.connections.count) {
            HStack(spacing: DS.Space.m) {
                Text("\(model.selected.count) selected").font(DS.Typo.caption).foregroundStyle(.secondary).monospacedDigit()
                Button(model.selected.count == preview.connections.count ? "Select None" : "Select All") { model.toggleAll() }
                    .controlSize(.small)
            }
        } content: {
            Group {
                if preview.connections.count > 6 {
                    ScrollView { rows(preview) }
                } else {
                    VStack(spacing: 0) {
                        rows(preview)
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(minHeight: 120, maxHeight: .infinity)
            .background(DS.Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous).strokeBorder(DS.Palette.separator.opacity(0.7), lineWidth: 0.5))
        }
        .disabled(model.running)
    }

    private func rows(_ preview: TablePlusImporter.Preview) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(preview.connections.enumerated()), id: \.element.id) { i, c in
                if i > 0 { Rectangle().fill(DS.Palette.separator.opacity(0.6)).frame(height: 0.5).padding(.leading, 40) }
                row(c)
                    .padding(.horizontal, DS.Space.l)
                    .padding(.vertical, DS.Space.s + DS.Space.xxs)
            }
        }
    }

    private func row(_ c: ConnectionConfig) -> some View {
        HStack(spacing: DS.Space.m + DS.Space.xxs) {
            Toggle("", isOn: Binding(get: { model.selected.contains(c.id) }, set: { on in
                if on { model.selected.insert(c.id) } else { model.selected.remove(c.id) }
            }))
            .labelsHidden()
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(c.accentColor).frame(width: 3, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DS.Space.s) {
                    Text(c.name).font(DS.Typo.body.weight(.medium)).lineLimit(1)
                    EnvironmentTag(environment: c.environment, colorHex: c.colorHex)
                    if c.ssh.enabled {
                        Image(systemName: "lock.shield").font(DS.Typo.caption).foregroundStyle(.secondary).help("Over SSH")
                    }
                }
                Text(c.subtitle).font(DS.Typo.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .layoutPriority(1)
            Spacer(minLength: DS.Space.m)
            if let g = model.groupName(c) {
                Label(g, systemImage: "folder").font(DS.Typo.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }
            Text(c.driver.displayName).font(DS.Typo.caption).foregroundStyle(.secondary).lineLimit(1).frame(width: 74, alignment: .trailing)
        }
    }

    private func summaryView(_ s: TablePlusImportSummary) -> some View {
        VStack(spacing: DS.Space.l) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 34, weight: .light)).foregroundStyle(.green)
            Text("Import complete").font(DS.Typo.title)
            Card {
                Grid(alignment: .leading, horizontalSpacing: DS.Space.xxl, verticalSpacing: DS.Space.s) {
                    summaryRow("Connections", "\(s.connections)")
                    summaryRow("Groups", "\(s.groups)")
                    summaryRow("Passwords", "\(s.passwords)")
                    summaryRow("History entries", Fmt.count(Int64(s.historyEntries)))
                }
                .font(DS.Typo.body)
            }
            .frame(width: 260)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}
