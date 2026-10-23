import AppKit
import MTPCore
import MTPUIKit
import SwiftUI
import UniformTypeIdentifiers

public enum ERColumnDisplay: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Every column with its type.
    case all
    /// Primary / foreign key columns only.
    case keys
    /// Every column, names without types.
    case names

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .all: return "All Columns"
        case .keys: return "Keys Only"
        case .names: return "Names Only"
        }
    }
}

struct ERColumnInfo: Hashable, Identifiable {
    var name: String
    var type: String
    var isPrimaryKey: Bool
    var isForeignKey: Bool
    var isNullable: Bool
    var nameWidth: CGFloat
    var typeWidth: CGFloat

    var id: String { name }
    var isKey: Bool { isPrimaryKey || isForeignKey }
}

/// Display data for one table box, with text widths measured once.
struct ERTableInfo: Hashable, Identifiable {
    static let headerHeight: CGFloat = 30
    static let rowHeight: CGFloat = 20
    static let bottomPadding: CGFloat = 6
    static let horizontalPadding: CGFloat = 10
    static let iconWidth: CGFloat = 14

    var id: String { name }
    var name: String
    var schema: String
    var kind: DBObjectKind
    var comment: String?
    var columns: [ERColumnInfo]
    var foreignKeys: [ForeignKeyRef]
    var headerWidth: CGFloat

    init(_ t: TableDetails) {
        name = t.object.name
        schema = t.object.schema
        kind = t.object.kind
        comment = t.object.comment
        let fkColumns = Set(t.foreignKeys.flatMap(\.columns))
        let pk = Set(t.primaryKey)
        columns = t.columns.sorted { $0.ordinal < $1.ordinal }.map { c in
            ERColumnInfo(name: c.name, type: ERTableInfo.shortType(c.dataType), isPrimaryKey: pk.contains(c.name),
                         isForeignKey: fkColumns.contains(c.name), isNullable: c.isNullable,
                         nameWidth: ERTableInfo.measure(c.name, font: .systemFont(ofSize: 11, weight: pk.contains(c.name) ? .semibold : .regular)),
                         typeWidth: ERTableInfo.measure(ERTableInfo.shortType(c.dataType), font: .monospacedSystemFont(ofSize: 10, weight: .regular)))
        }
        foreignKeys = t.foreignKeys
        headerWidth = ERTableInfo.measure(t.object.name, font: .systemFont(ofSize: 12, weight: .semibold))
    }

    static func measure(_ s: String, font: NSFont) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: font]).width)
    }

    /// Long catalog names shortened for the box ("timestamp with time zone" → "timestamptz").
    static func shortType(_ t: String) -> String {
        t.replacingOccurrences(of: "timestamp with time zone", with: "timestamptz")
            .replacingOccurrences(of: "timestamp without time zone", with: "timestamp")
            .replacingOccurrences(of: "character varying", with: "varchar")
            .replacingOccurrences(of: "double precision", with: "float8")
            .replacingOccurrences(of: "time with time zone", with: "timetz")
            .replacingOccurrences(of: "time without time zone", with: "time")
    }

    func visibleColumns(_ mode: ERColumnDisplay) -> [ERColumnInfo] {
        mode == .keys ? columns.filter(\.isKey) : columns
    }

    func size(_ mode: ERColumnDisplay) -> CGSize {
        let cols = visibleColumns(mode)
        var w = headerWidth + 2 * Self.horizontalPadding + 22
        for c in cols {
            var rw = 2 * Self.horizontalPadding + Self.iconWidth + 6 + c.nameWidth
            if mode != .names { rw += 16 + c.typeWidth }
            w = max(w, rw)
        }
        let width = min(max(w, 150), 380)
        let height = Self.headerHeight + CGFloat(cols.count) * Self.rowHeight + (cols.isEmpty ? 0 : Self.bottomPadding)
        return CGSize(width: width, height: height)
    }

    /// Vertical centre of a column row relative to the box top, or the header centre when hidden.
    func anchorY(column: String?, mode: ERColumnDisplay) -> CGFloat {
        if let column, let i = visibleColumns(mode).firstIndex(where: { $0.name == column }) {
            return Self.headerHeight + CGFloat(i) * Self.rowHeight + Self.rowHeight / 2
        }
        return Self.headerHeight / 2
    }
}

struct EREdge: Hashable, Identifiable {
    var child: String
    var childColumn: String?
    var parent: String
    var parentColumn: String?
    var constraint: String

    var id: String { "\(child).\(constraint)" }
}

/// Saved manual layout: AppPaths.diagramsDirectory/<connectionID>-<schema>.json
struct DiagramLayoutFile: Codable, Equatable {
    var version = 1
    var positions: [String: [Double]]
    var displayMode: ERColumnDisplay?
    var showViews: Bool?

    static func url(connectionID: UUID, schema: String) -> URL {
        let safe = schema.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return AppPaths.diagramsDirectory.appendingPathComponent("\(connectionID.uuidString)-\(safe).json")
    }

    static func load(connectionID: UUID, schema: String) -> DiagramLayoutFile? {
        guard let data = try? Data(contentsOf: url(connectionID: connectionID, schema: schema)) else { return nil }
        return try? JSONDecoder().decode(DiagramLayoutFile.self, from: data)
    }

    func save(connectionID: UUID, schema: String) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: Self.url(connectionID: connectionID, schema: schema), options: .atomic)
    }

    static func delete(connectionID: UUID, schema: String) {
        try? FileManager.default.removeItem(at: url(connectionID: connectionID, schema: schema))
    }
}

/// Everything the table/edge layer draws; compared to skip redraws while only pan/zoom changes.
struct ERContentState: Equatable {
    var tables: [ERTableInfo]
    var positions: [String: CGPoint]
    var mode: ERColumnDisplay
    var selection: String?
    var related: Set<String>
    var matches: Set<String>
    var edges: [EREdge]

    func frame(_ name: String) -> CGRect? {
        guard let t = tables.first(where: { $0.name == name }), let p = positions[name] else { return nil }
        return CGRect(origin: p, size: t.size(mode))
    }

    /// Union of every box, padded.
    var bounds: CGRect {
        var r = CGRect.null
        for t in tables {
            if let p = positions[t.name] { r = r.union(CGRect(origin: p, size: t.size(mode))) }
        }
        return r.isNull ? CGRect(x: 0, y: 0, width: 400, height: 300) : r.insetBy(dx: -60, dy: -60)
    }
}

@MainActor
final class ERDiagramModel: ObservableObject {
    let context: WorkspaceContext
    let schema: String

    @Published private(set) var tables: [ERTableInfo] = []
    @Published var positions: [String: CGPoint] = [:]
    @Published var zoom: CGFloat = 1
    @Published var pan: CGSize = .zero
    @Published var selection: String?
    @Published var search = "" { didSet { updateMatches() } }
    @Published private(set) var matches: Set<String> = []
    @Published var mode: ERColumnDisplay = .all {
        didSet { if oldValue != mode && !restoring { modeChanged() } }
    }
    @Published var showViews = false {
        didSet {
            guard oldValue != showViews && !restoring else { return }
            rebuild(keepPositions: true)
            saveLayout()
        }
    }
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasManualLayout = false
    @Published private(set) var edges: [EREdge] = []

    var viewportSize: CGSize = .zero
    var hoverLocation: CGPoint?
    private var allTables: [TableDetails] = []
    private var dragStart: CGPoint?
    private var panStart: CGSize?
    private var zoomStart: CGFloat?
    private var monitor: Any?
    private var didInitialFit = false
    /// Set while applying a saved layout so property observers do not save over it.
    private var restoring = false

    static let minZoom: CGFloat = 0.15
    static let maxZoom: CGFloat = 3

    init(context: WorkspaceContext, schema: String) {
        self.context = context
        self.schema = schema
    }

    var connectionID: UUID { context.connection.id }

    var contentState: ERContentState {
        ERContentState(tables: tables, positions: positions, mode: mode, selection: selection, related: related,
                       matches: matches, edges: edges)
    }

    /// Tables linked to the selection by a foreign key, in either direction.
    var related: Set<String> {
        guard let s = selection else { return [] }
        var out = Set<String>()
        for e in edges {
            if e.child == s { out.insert(e.parent) }
            if e.parent == s { out.insert(e.child) }
        }
        out.remove(s)
        return out
    }

    // MARK: Loading

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            allTables = try await context.introspector.snapshot(schema: schema)
            let saved = DiagramLayoutFile.load(connectionID: connectionID, schema: schema)
            restoring = true
            if let saved {
                if let m = saved.displayMode { mode = m }
                if let v = saved.showViews { showViews = v }
            }
            restoring = false
            rebuild(keepPositions: false)
            if let saved, !saved.positions.isEmpty {
                applySaved(saved.positions)
            }
            didInitialFit = false
            fitIfPossible()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// For previews and tests: use already introspected tables.
    func setTables(_ details: [TableDetails]) {
        allTables = details
        rebuild(keepPositions: false)
    }

    private func rebuild(keepPositions: Bool) {
        let kinds: Set<DBObjectKind> = showViews ? [.table, .foreignTable, .view, .materializedView] : [.table, .foreignTable]
        tables = allTables.filter { kinds.contains($0.object.kind) }.map(ERTableInfo.init)
        let names = Set(tables.map(\.name))
        edges = tables.flatMap { t in
            t.foreignKeys.filter { $0.refSchema == t.schema && names.contains($0.refTable) }.map { fk in
                EREdge(child: t.name, childColumn: fk.columns.first, parent: fk.refTable, parentColumn: fk.refColumns.first, constraint: fk.constraintName)
            }
        }
        if keepPositions && !positions.isEmpty {
            let missing = tables.filter { positions[$0.name] == nil }
            positions = positions.filter { names.contains($0.key) }
            if !missing.isEmpty { placeBesideExisting(missing) }
        } else {
            autoLayout()
        }
        updateMatches()
    }

    func autoLayout() {
        let nodes = tables.map { ERLayout.Node(id: $0.name, size: $0.size(mode)) }
        let e = edges.map { ERLayout.Edge(child: $0.child, parent: $0.parent) }
        positions = ERLayout.layout(nodes: nodes, edges: e)
    }

    private func applySaved(_ saved: [String: [Double]]) {
        var known: [String: CGPoint] = [:]
        for (k, v) in saved where v.count == 2 { known[k] = CGPoint(x: v[0], y: v[1]) }
        let names = Set(tables.map(\.name))
        let usable = known.filter { names.contains($0.key) }
        guard !usable.isEmpty else { return }
        hasManualLayout = true
        positions = usable
        let missing = tables.filter { usable[$0.name] == nil }
        if !missing.isEmpty { placeBesideExisting(missing) }
    }

    /// New tables (not in the saved layout) are laid out on their own to the right of the existing ones.
    private func placeBesideExisting(_ missing: [ERTableInfo]) {
        let existing = contentState.bounds
        let names = Set(missing.map(\.name))
        let nodes = missing.map { ERLayout.Node(id: $0.name, size: $0.size(mode)) }
        let e = edges.filter { names.contains($0.child) && names.contains($0.parent) }.map { ERLayout.Edge(child: $0.child, parent: $0.parent) }
        let sub = ERLayout.layout(nodes: nodes, edges: e)
        let dx = positions.isEmpty ? 0 : existing.maxX + 40
        for (k, p) in sub { positions[k] = CGPoint(x: p.x + dx, y: p.y + (positions.isEmpty ? 0 : existing.minY)) }
    }

    private func modeChanged() {
        if !hasManualLayout { autoLayout() }
        saveLayout()
    }

    func resetLayout() {
        hasManualLayout = false
        DiagramLayoutFile.delete(connectionID: connectionID, schema: schema)
        autoLayout()
        fit()
        saveLayout()
    }

    func saveLayout() {
        guard !tables.isEmpty || hasManualLayout else { return }
        let file = DiagramLayoutFile(positions: hasManualLayout ? positions.mapValues { [Double($0.x), Double($0.y)] } : [:],
                                     displayMode: mode, showViews: showViews)
        try? file.save(connectionID: connectionID, schema: schema)
    }

    // MARK: Interaction

    func select(_ name: String?) { selection = name }

    func open(_ name: String) {
        guard let t = tables.first(where: { $0.name == name }) else { return }
        context.openTable(schema: t.schema, name: t.name)
    }

    func drag(_ name: String, translation: CGSize) {
        if dragStart == nil {
            dragStart = positions[name]
            selection = name
        }
        guard let start = dragStart else { return }
        positions[name] = CGPoint(x: start.x + translation.width / zoom, y: start.y + translation.height / zoom)
    }

    func endDrag() {
        guard dragStart != nil else { return }
        dragStart = nil
        hasManualLayout = true
        saveLayout()
    }

    func panBy(_ translation: CGSize) {
        if panStart == nil { panStart = pan }
        guard let s = panStart else { return }
        pan = CGSize(width: s.width + translation.width, height: s.height + translation.height)
    }

    func endPan() { panStart = nil }

    /// Zoom keeping `anchor` (viewport coordinates) fixed; defaults to the viewport centre.
    func setZoom(_ z: CGFloat, anchor: CGPoint? = nil) {
        let newZoom = min(max(z, Self.minZoom), Self.maxZoom)
        let a = anchor ?? CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
        let cx = (a.x - pan.width) / zoom
        let cy = (a.y - pan.height) / zoom
        zoom = newZoom
        pan = CGSize(width: a.x - cx * newZoom, height: a.y - cy * newZoom)
    }

    func zoomIn() { setZoom(zoom * 1.25) }
    func zoomOut() { setZoom(zoom / 1.25) }

    func magnify(by factor: CGFloat, anchor: CGPoint?) {
        if zoomStart == nil { zoomStart = zoom }
        setZoom((zoomStart ?? zoom) * factor, anchor: anchor)
    }

    func endMagnify() { zoomStart = nil }

    func fit() {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return }
        let b = contentState.bounds
        let z = min(max(min(viewportSize.width / b.width, viewportSize.height / b.height), Self.minZoom), 1)
        zoom = z
        pan = CGSize(width: (viewportSize.width - b.width * z) / 2 - b.minX * z,
                     height: (viewportSize.height - b.height * z) / 2 - b.minY * z)
    }

    func fitIfPossible() {
        guard !didInitialFit, !tables.isEmpty, viewportSize.width > 0 else { return }
        didInitialFit = true
        fit()
    }

    func viewportResized(_ size: CGSize) {
        viewportSize = size
        fitIfPossible()
    }

    /// Selects the table and brings it to the middle of the viewport.
    func center(on name: String, animated: Bool = true) {
        guard let f = contentState.frame(name) else { return }
        selection = name
        let target = CGSize(width: viewportSize.width / 2 - f.midX * zoom, height: viewportSize.height / 2 - f.midY * zoom)
        if animated {
            withAnimation(.easeInOut(duration: 0.3)) { pan = target }
        } else {
            pan = target
        }
    }

    private func updateMatches() {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        matches = q.isEmpty ? [] : Set(tables.filter { $0.name.lowercased().contains(q) }.map(\.name))
    }

    /// Best match: exact name, then prefix, then substring.
    func revealSearch() {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return }
        let names = tables.map(\.name).sorted()
        let hit = names.first { $0.lowercased() == q } ?? names.first { $0.lowercased().hasPrefix(q) } ?? names.first { $0.lowercased().contains(q) }
        if let hit { center(on: hit) }
    }

    // MARK: Scroll wheel / pinch

    func installEventMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
            guard let self else { return event }
            let handled = MainActor.assumeIsolated { self.handle(event) }
            return handled ? nil : event
        }
    }

    func removeEventMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let anchor = hoverLocation else { return false }
        switch event.type {
        case .magnify:
            setZoom(zoom * (1 + event.magnification), anchor: anchor)
            return true
        case .scrollWheel:
            if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
                let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
                setZoom(zoom * exp(delta * 0.01), anchor: anchor)
            } else {
                let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
                pan = CGSize(width: pan.width + event.scrollingDeltaX * k, height: pan.height + event.scrollingDeltaY * k)
            }
            return true
        default:
            return false
        }
    }

    // MARK: Export

    /// Renders the whole diagram (zoom 1) to PNG data.
    func pngData(colorScheme: ColorScheme = .light) -> Data? {
        let state = contentState
        let b = state.bounds
        let maxSide = max(b.width, b.height)
        let scale = min(2, 8000 / max(maxSide, 1))
        let view = ERExportView(state: state, accent: context.connection.accentColor)
            .environment(\.colorScheme, colorScheme)
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let cg = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    func exportPNG() {
        guard let url = FilePanels.chooseSaveURL(suggestedName: "\(context.connection.name.isEmpty ? "diagram" : context.connection.name)-\(schema).png", types: [.png]) else { return }
        guard let data = pngData() else {
            context.showToast("Could not render the diagram")
            return
        }
        do {
            try data.write(to: url, options: .atomic)
            context.showToast("Diagram exported")
        } catch {
            context.showError(error)
        }
    }
}
