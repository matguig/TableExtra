import FeatureAI
import FeatureDataTransfer
import MTPCore
import MTPUIKit
import SwiftUI

struct SettingsView: View {
    enum Page: String, CaseIterable, Identifiable {
        case general = "General", editor = "Editor", ai = "AI", mcp = "MCP", data = "Data"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .editor: return "chevron.left.forwardslash.chevron.right"
            case .ai: return "sparkles"
            case .mcp: return "point.3.filled.connected.trianglepath.dotted"
            case .data: return "externaldrive"
            }
        }
        var subtitle: String {
            switch self {
            case .general: return "Appearance, data grid and results"
            case .editor: return "SQL editor and completion"
            case .ai: return "Claude assistant"
            case .mcp: return "Access for Claude Code and other agents"
            case .data: return "Storage, import and history"
            }
        }
    }

    @State private var page: Page = .general

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Page.allCases) { p in
                    HoverRow(action: { page = p }) {
                        Image(systemName: p.icon).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(page == p ? Color.accentColor : Color.secondary).frame(width: 18)
                        Text(p.rawValue).font(DS.Typo.body).fontWeight(page == p ? .medium : .regular)
                        Spacer(minLength: 0)
                    }
                    .background(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).fill(page == p ? Color.primary.opacity(0.07) : .clear))
                }
                Spacer()
            }
            .padding(DS.Space.m)
            .padding(.top, DS.Space.xs)
            .frame(width: 180)
            .background(DS.Palette.bar)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(page.rawValue).font(DS.Typo.title)
                    Text(page.subtitle).font(DS.Typo.callout).foregroundStyle(.secondary)
                }
                .padding(.horizontal, DS.Space.xxl)
                .padding(.top, DS.Space.xl)
                .padding(.bottom, DS.Space.xs)
                Group {
                    switch page {
                    case .general: GeneralSettings()
                    case .editor: EditorSettings()
                    case .ai: AISettingsView()
                    case .mcp: MCPSettingsView()
                    case .data: DataSettings()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(minWidth: 720, minHeight: 500)
    }
}

/// Settings row: title + grey description on the left, control on the right (Buffer / Replit style).
struct SettingRow<Control: View>: View {
    var title: String
    var detail: String?
    @ViewBuilder var control: Control

    var body: some View {
        LabeledContent {
            control
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail { Text(detail).font(DS.Typo.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }
}

private struct GeneralSettings: View {
    @AppStorage(SettingKey.appearance) private var appearance = "system"
    @AppStorage(SettingKey.pageSize) private var pageSize = 300
    @AppStorage(SettingKey.nullText) private var nullText = "NULL"
    @AppStorage(SettingKey.gridFontSize) private var gridFontSize = 12.0
    @AppStorage(SettingKey.showRowNumbers) private var showRowNumbers = true
    @AppStorage(SettingKey.queryRowLimit) private var rowLimit = 10_000
    @AppStorage(SettingKey.estimateCountThreshold) private var estimateThreshold = 500_000
    @AppStorage(SettingKey.restoreWorkspaces) private var restore = true
    @AppStorage(SettingKey.openInsightsOnConnect) private var openInsights = true

    var body: some View {
        Form {
            Section {
                SettingRow(title: "Appearance") {
                    CompactSegmented([(label: "System", value: "system"), (label: "Light", value: "light"), (label: "Dark", value: "dark")], selection: $appearance)
                }
                .onChange(of: appearance) { _, _ in AppSettings.applyAppearance() }
                SettingRow(title: "Reopen workspaces at launch", detail: "Restore open connections and their tabs") {
                    Toggle("", isOn: $restore).toggleStyle(.switch).labelsHidden()
                }
                SettingRow(title: "Open Insights on connect", detail: "Show the database health dashboard first when a connection opens") {
                    Toggle("", isOn: $openInsights).toggleStyle(.switch).labelsHidden()
                }
            }
            Section("Data grid") {
                SettingRow(title: "Rows per page", detail: "Rows loaded per page when browsing a table") {
                    stepper("\(pageSize)", $pageSize, 50...10_000, 50)
                }
                SettingRow(title: "NULL shown as") {
                    TextField("", text: $nullText).textFieldStyle(.roundedBorder).frame(width: 100).multilineTextAlignment(.trailing)
                }
                SettingRow(title: "Font size") { stepperD("\(Int(gridFontSize)) pt", $gridFontSize, 9...20) }
                SettingRow(title: "Row numbers", detail: "Show a numbered gutter on the left of the grid") {
                    Toggle("", isOn: $showRowNumbers).toggleStyle(.switch).labelsHidden()
                }
                SettingRow(title: "Estimate counts above", detail: "Use planner estimates instead of COUNT(*) on big tables") {
                    stepper(Fmt.count(Int64(estimateThreshold)), $estimateThreshold, 10_000...100_000_000, 100_000)
                }
            }
            Section("Query results") {
                SettingRow(title: "Row limit", detail: "Stop fetching a result after this many rows") {
                    stepper(Fmt.count(Int64(rowLimit)), $rowLimit, 100...1_000_000, 1000)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private func stepper(_ text: String, _ value: Binding<Int>, _ range: ClosedRange<Int>, _ step: Int) -> some View {
    HStack(spacing: DS.Space.s) {
        Text(text).monospacedDigit().foregroundStyle(.secondary)
        Stepper("", value: value, in: range, step: step).labelsHidden()
    }
}

private func stepperD(_ text: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
    HStack(spacing: DS.Space.s) {
        Text(text).monospacedDigit().foregroundStyle(.secondary)
        Stepper("", value: value, in: range).labelsHidden()
    }
}

private struct EditorSettings: View {
    @AppStorage(SettingKey.editorFontSize) private var fontSize = 13.0
    @AppStorage(SettingKey.autoCompletion) private var autoCompletion = true
    @AppStorage(SettingKey.uppercaseCompletion) private var uppercase = true
    @AppStorage(SettingKey.indentWidth) private var indent = 2

    var body: some View {
        Form {
            Section {
                SettingRow(title: "Font size") { stepperD("\(Int(fontSize)) pt", $fontSize, 9...28) }
                    .onChange(of: fontSize) { _, _ in NotificationCenter.default.post(name: .mtpFontSizeChanged, object: nil) }
                SettingRow(title: "Indent width") { stepper("\(indent)", $indent, 1...8, 1) }
            }
            Section("Completion") {
                SettingRow(title: "Suggest while typing", detail: "⌃Space always opens suggestions") {
                    Toggle("", isOn: $autoCompletion).toggleStyle(.switch).labelsHidden()
                }
                SettingRow(title: "Uppercase keywords", detail: "Applies to completion and the SQL formatter") {
                    Toggle("", isOn: $uppercase).toggleStyle(.switch).labelsHidden()
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct DataSettings: View {
    @State private var confirmClear = false
    @State private var showImport = false

    var body: some View {
        Form {
            Section("Storage") {
                SettingRow(title: "Data folder", detail: "Connections live in connections.json; passwords only in the macOS Keychain") {
                    Button("Show in Finder") { NSWorkspace.shared.open(AppPaths.root) }
                }
            }
            Section("TablePlus") {
                SettingRow(title: "Import from TablePlus", detail: "Connections, groups and optionally passwords and history") {
                    Button("Import…") { showImport = true }.disabled(!TablePlusImporter().isAvailable)
                }
            }
            Section("History") {
                SettingRow(title: "Query history", detail: "Every executed statement, kept locally") {
                    Button("Clear…", role: .destructive) { confirmClear = true }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete every saved query from history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { HistoryStore.shared.clear(connectionID: nil) }
        }
        .sheet(isPresented: $showImport) {
            TablePlusImportView(onClose: { showImport = false }).frame(minWidth: 620, minHeight: 520)
        }
    }
}
