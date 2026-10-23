import FeatureDataTransfer
import Foundation
import MTPCore

/// Anything that can live in the workspace tab bar.
@MainActor
protocol WorkspaceTab: AnyObject {
    var id: UUID { get }
    var title: String { get }
    var icon: String { get }
    /// Preview tabs (single click in the sidebar) are replaced by the next preview, like TablePlus.
    var isPreview: Bool { get set }
    var hasUnsavedChanges: Bool { get }
}

enum FeatureKind: Equatable {
    case insights
    case processList
    case diagram(schema: String)
    case schemaDiff
    case typeScript(schema: String, tables: [String]?)
    case explain(sql: String)
    case history
    case favorites
    case databaseSearch
    case rds

    var title: String {
        switch self {
        case .insights: return "Insights"
        case .processList: return "Processes"
        case .diagram(let s): return "Diagram · \(s)"
        case .schemaDiff: return "Schema Diff"
        case .typeScript: return "Kysely Types"
        case .explain: return "Explain"
        case .history: return "History"
        case .favorites: return "Favorites"
        case .databaseSearch: return "Search"
        case .rds: return "AWS RDS"
        }
    }

    var icon: String {
        switch self {
        case .insights: return "gauge.with.dots.needle.67percent"
        case .processList: return "list.bullet.rectangle"
        case .diagram: return "point.3.connected.trianglepath.dotted"
        case .schemaDiff: return "arrow.left.arrow.right.square"
        case .typeScript: return "curlybraces.square"
        case .explain: return "chart.bar.doc.horizontal"
        case .history: return "clock.arrow.circlepath"
        case .favorites: return "star"
        case .databaseSearch: return "magnifyingglass"
        case .rds: return "cloud"
        }
    }
}

@MainActor
@Observable
final class FeatureTabModel: WorkspaceTab {
    let id = UUID()
    let kind: FeatureKind
    var isPreview = false
    var hasUnsavedChanges: Bool { false }
    var title: String { kind.title }
    var icon: String { kind.icon }

    init(kind: FeatureKind) { self.kind = kind }
}

/// Executed statements of the session (bottom console, TablePlus "Command Logger").
struct ConsoleEntry: Identifiable {
    let id = UUID()
    var date = Date()
    var sql: String
    var duration: TimeInterval
    var outcome: String
    var isError: Bool
}

/// Modal sheets presented over the workspace window.
enum WorkspaceSheet: Identifiable {
    case export(ExportSource)
    case importCSV(schema: String, table: String?)
    case backup
    case restore
    case editConnection
    case preview(title: String, sql: String)

    var id: String {
        switch self {
        case .export: return "export"
        case .importCSV: return "import"
        case .backup: return "backup"
        case .restore: return "restore"
        case .editConnection: return "edit"
        case .preview: return "preview"
        }
    }
}
