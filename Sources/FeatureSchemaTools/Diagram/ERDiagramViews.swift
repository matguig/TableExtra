import AppKit
import MTPCore
import MTPUIKit
import SwiftUI

/// Owns the model for the public `ERDiagramView`.
struct ERDiagramScreen: View {
    @StateObject private var model: ERDiagramModel

    init(context: WorkspaceContext, schema: String) {
        _model = StateObject(wrappedValue: ERDiagramModel(context: context, schema: schema))
    }

    var body: some View {
        ERDiagramContent(model: model)
            .task { await model.load() }
    }
}

struct ERDiagramContent: View {
    @ObservedObject var model: ERDiagramModel

    var body: some View {
        VStack(spacing: 0) {
            ERDiagramToolbar(model: model)
            ZStack {
                ERViewport(model: model)
                if model.isLoading && model.tables.isEmpty {
                    ProgressView("Loading \(model.schema)…").controlSize(.small)
                } else if let error = model.errorMessage {
                    Banner(.error, error).frame(minWidth: 280, maxWidth: 520).padding(DS.Space.xl)
                } else if !model.isLoading && model.tables.isEmpty {
                    EmptyState("No tables in \(model.schema)", systemImage: "point.3.connected.trianglepath.dotted",
                               message: "Tables and their foreign keys appear here once the schema has some.")
                        .background(DS.Palette.canvas)
                }
            }
            if let s = model.selection, let t = model.tables.first(where: { $0.name == s }) {
                ERSelectionBar(model: model, table: t)
            }
        }
    }
}

/// Compact search field sized for a `ToolStrip` (24pt high, tinted fill, no bezel).
struct ToolSearchField: View {
    var prompt: String
    @Binding var text: String
    /// Fixed width; nil fills the available width.
    var width: CGFloat? = 160
    var count: Int?
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(DS.Typo.callout)
                .onSubmit(onSubmit)
            if !text.isEmpty {
                if let count {
                    Text("\(count)").font(DS.Typo.caption).monospacedDigit().foregroundStyle(.secondary).fixedSize()
                }
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
                    .help("Clear")
            }
        }
        .padding(.horizontal, DS.Space.s)
        .frame(width: width, height: 24)
        .frame(maxWidth: width == nil ? .infinity : nil)
        .background(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).strokeBorder(DS.Palette.separator.opacity(0.6), lineWidth: 0.5))
    }
}

/// On/off tool button for `ToolStrip`: tinted when on, collapses to its icon when the strip is narrow.
struct ToolToggle: View {
    var title: String
    var systemImage: String
    @Binding var isOn: Bool
    var help: String?
    @Environment(\.toolStripCompact) private var compact
    @State private var hover = false

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 11.5, weight: .medium)).frame(width: 14)
                if !compact { Text(title).lineLimit(1).fixedSize() }
            }
            .font(.system(size: 12, weight: isOn ? .medium : .regular))
            .foregroundStyle(isOn ? Color.accentColor : Color.primary.opacity(0.85))
            .padding(.horizontal, compact ? 6 : 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                .fill(isOn ? Color.accentColor.opacity(0.12) : (hover ? DS.Palette.hover : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help ?? title)
    }
}

/// Small text shown in a `ToolStrip` only when there is room for it.
struct ToolCaption: View {
    var text: String
    @Environment(\.toolStripCompact) private var compact

    var body: some View {
        if !compact {
            Text(text).font(DS.Typo.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1).fixedSize()
                .padding(.horizontal, DS.Space.xs)
        }
    }
}

/// Invisible buttons carrying keyboard shortcuts, kept out of `ToolStrip` (which may build its row twice).
struct HiddenShortcut: View {
    var key: KeyEquivalent
    var modifiers: EventModifiers = .command
    var action: () -> Void

    var body: some View {
        Button("", action: action)
            .keyboardShortcut(key, modifiers: modifiers)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
    }
}

struct ERDiagramToolbar: View {
    @ObservedObject var model: ERDiagramModel

    var body: some View {
        ToolStrip {
            ToolSearchField(prompt: "Find table", text: $model.search, width: 170,
                            count: model.search.isEmpty ? nil : model.matches.count) { model.revealSearch() }
            ToolDivider()
            CompactSegmented(ERColumnDisplay.allCases.map { (label: $0.shortTitle, value: $0) }, selection: $model.mode)
                .help("Columns shown in each table")
            ToolToggle(title: "Views", systemImage: "eye", isOn: $model.showViews, help: "Show views and materialized views")
        } trailing: {
            ToolCaption(text: "\(model.tables.count) tables · \(model.edges.count) relations")
            ToolDivider()
            ToolButton("Zoom Out", systemImage: "minus.magnifyingglass", shortcut: "⌘−") { model.zoomOut() }
                .environment(\.toolStripCompact, true)
            Button { model.setZoom(1) } label: {
                Text("\(Int((model.zoom * 100).rounded()))%")
                    .font(DS.Typo.callout).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Actual Size")
            ToolButton("Zoom In", systemImage: "plus.magnifyingglass", shortcut: "⌘+") { model.zoomIn() }
                .environment(\.toolStripCompact, true)
            ToolButton("Zoom to Fit", systemImage: "arrow.up.left.and.down.right.magnifyingglass", shortcut: "⌘0") { model.fit() }
                .environment(\.toolStripCompact, true)
            ToolDivider()
            ToolButton("Auto Layout", systemImage: "wand.and.stars") { model.resetLayout() }
            ToolButton("Export PNG…", systemImage: "square.and.arrow.up") { model.exportPNG() }
                .disabled(model.tables.isEmpty)
        }
        .background {
            HiddenShortcut(key: "-") { model.zoomOut() }
            HiddenShortcut(key: "+") { model.zoomIn() }
            // ⌘= is what most keyboards send for ⌘+.
            HiddenShortcut(key: "=") { model.zoomIn() }
            HiddenShortcut(key: "0") { model.fit() }
        }
    }
}

extension ERColumnDisplay {
    /// Short segment label that never wraps in the toolbar.
    var shortTitle: String {
        switch self {
        case .all: return "All"
        case .keys: return "Keys"
        case .names: return "Names"
        }
    }
}

struct ERSelectionBar: View {
    @ObservedObject var model: ERDiagramModel
    let table: ERTableInfo

    var body: some View {
        let refs = Array(Set(model.edges.filter { $0.child == table.name }.map(\.parent))).sorted()
        let refBy = Array(Set(model.edges.filter { $0.parent == table.name }.map(\.child))).sorted()
        HStack(spacing: DS.Space.l) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: table.kind.symbolName).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(table.name).font(DS.Typo.headline).lineLimit(1)
            }
            .layoutPriority(2)
            Text("\(table.columns.count) columns").font(DS.Typo.caption).monospacedDigit().foregroundStyle(.secondary).fixedSize()
            if !refs.isEmpty {
                Label(refs.joined(separator: ", "), systemImage: "arrow.right")
                    .font(DS.Typo.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    .help("References " + refs.joined(separator: ", "))
            }
            if !refBy.isEmpty {
                Label(refBy.joined(separator: ", "), systemImage: "arrow.left")
                    .font(DS.Typo.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    .help("Referenced by " + refBy.joined(separator: ", "))
            }
            Spacer(minLength: DS.Space.m)
            ToolButton("Open Table", systemImage: "tablecells") { model.open(table.name) }
        }
        .padding(.horizontal, DS.Space.l)
        .frame(height: 32)
        .background(DS.Palette.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// Pannable / zoomable area. Pan and zoom only change the transform of the (equatable) content layer.
struct ERViewport: View {
    @ObservedObject var model: ERDiagramModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geo in
            let state = model.contentState
            let b = state.bounds
            ERGridBackground(zoom: model.zoom, pan: model.pan)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .named("erViewport"))
                        .onChanged { model.panBy($0.translation) }
                        .onEnded { _ in model.endPan() }
                )
                .onTapGesture { model.select(nil) }
                .overlay(alignment: .topLeading) {
                    ERContentLayer(state: state, origin: b.origin, accent: model.context.connection.accentColor, model: model)
                        .equatable()
                        .frame(width: b.width, height: b.height, alignment: .topLeading)
                        .scaleEffect(model.zoom, anchor: .topLeading)
                        .offset(x: model.pan.width + b.minX * model.zoom, y: model.pan.height + b.minY * model.zoom)
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .clipped()
                .coordinateSpace(.named("erViewport"))
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { model.magnify(by: $0.magnification, anchor: model.hoverLocation) }
                        .onEnded { _ in model.endMagnify() }
                )
                .onContinuousHover(coordinateSpace: .named("erViewport")) { phase in
                    switch phase {
                    case .active(let p): model.hoverLocation = p
                    case .ended: model.hoverLocation = nil
                    }
                }
                .onAppear {
                    model.viewportResized(geo.size)
                    model.installEventMonitor()
                }
                .onDisappear { model.removeEventMonitor() }
                .onChange(of: geo.size) { _, s in model.viewportResized(s) }
        }
    }
}

struct ERGridBackground: View {
    var zoom: CGFloat
    var pan: CGSize

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(DS.Palette.canvas))
            var step: CGFloat = 20 * zoom
            while step < 12 { step *= 2 }
            let r: CGFloat = 0.6
            let ox = pan.width.truncatingRemainder(dividingBy: step)
            let oy = pan.height.truncatingRemainder(dividingBy: step)
            var dots = Path()
            var x = ox < 0 ? ox + step : ox
            while x < size.width {
                var y = oy < 0 ? oy + step : oy
                while y < size.height {
                    dots.addEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
                    y += step
                }
                x += step
            }
            ctx.fill(dots, with: .color(Color.primary.opacity(0.16)))
        }
    }
}

/// Edges (Canvas) + table boxes in content coordinates shifted by `origin`.
struct ERContentLayer: View, Equatable {
    let state: ERContentState
    let origin: CGPoint
    let accent: Color
    /// Interactions; nil for export rendering.
    let model: ERDiagramModel?

    static func == (a: ERContentLayer, b: ERContentLayer) -> Bool {
        a.state == b.state && a.origin == b.origin && a.accent == b.accent && (a.model === b.model)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                ERDrawing.edges(in: &ctx, state: state, origin: origin, accent: accent)
            }
            .allowsHitTesting(false)
            ForEach(state.tables) { t in
                let p = state.positions[t.name] ?? .zero
                box(t)
                    .offset(x: p.x - origin.x, y: p.y - origin.y)
            }
        }
    }

    func look(_ name: String) -> ERTableBox.Look {
        if state.selection == name { return .selected }
        if state.matches.contains(name) { return .match }
        if state.related.contains(name) { return .related }
        if state.selection != nil || !state.matches.isEmpty { return .dimmed }
        return .normal
    }

    @ViewBuilder
    func box(_ t: ERTableInfo) -> some View {
        let view = ERTableBox(table: t, mode: state.mode, look: look(t.name), accent: accent).equatable()
        if let model {
            view
                .contentShape(RoundedRectangle(cornerRadius: DS.Radius.m + 2, style: .continuous))
                .gesture(
                    DragGesture(minimumDistance: 2, coordinateSpace: .named("erViewport"))
                        .onChanged { model.drag(t.name, translation: $0.translation) }
                        .onEnded { _ in model.endDrag() }
                )
                .onTapGesture(count: 2) { model.open(t.name) }
                .simultaneousGesture(TapGesture().onEnded { model.select(t.name) })
                .contextMenu {
                    Button("Open Table") { model.open(t.name) }
                    Button("Copy Name") { Pasteboard.copy(t.name) }
                    Button("Center") { model.center(on: t.name) }
                }
                .help(t.comment ?? t.name)
        } else {
            view
        }
    }
}

struct ERTableBox: View, Equatable {
    enum Look: Equatable { case normal, selected, related, match, dimmed }

    let table: ERTableInfo
    let mode: ERColumnDisplay
    let look: Look
    let accent: Color

    var body: some View {
        let size = table.size(mode)
        let isView = table.kind == .view || table.kind == .materializedView
        let tint = isView ? Color.purple : accent
        let shape = RoundedRectangle(cornerRadius: DS.Radius.m + 2, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: table.kind.symbolName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: ERTableInfo.iconWidth)
                Text(table.name).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, ERTableInfo.horizontalPadding)
            .frame(height: ERTableInfo.headerHeight)
            .frame(maxWidth: .infinity)
            .background(tint.opacity(look == .selected ? 0.14 : 0.07))
            .overlay(alignment: .bottom) { Rectangle().fill(DS.Palette.separator.opacity(0.8)).frame(height: 0.5) }

            ForEach(table.visibleColumns(mode)) { c in
                HStack(spacing: 6) {
                    Group {
                        if c.isPrimaryKey {
                            Image(systemName: "key.fill").foregroundStyle(Color.orange)
                        } else if c.isForeignKey {
                            Image(systemName: "link").foregroundStyle(Color.blue)
                        } else {
                            Color.clear
                        }
                    }
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: ERTableInfo.iconWidth, height: ERTableInfo.rowHeight, alignment: .center)
                    Text(c.name)
                        .font(.system(size: 11, weight: c.isPrimaryKey ? .semibold : .regular))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if mode != .names {
                        Text(c.type)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, ERTableInfo.horizontalPadding)
                .frame(height: ERTableInfo.rowHeight)
            }
            Spacer(minLength: 0)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        // Surface over an opaque canvas so edges never show through the card in dark mode.
        .background(DS.Palette.surface)
        .background(DS.Palette.canvas)
        .clipShape(shape)
        .overlay(shape.strokeBorder(borderColor, lineWidth: borderWidth))
        .background(shape.fill(DS.Palette.canvas).shadow(color: .black.opacity(look == .selected ? 0.16 : 0.08), radius: look == .selected ? 6 : 3, y: 1))
        .opacity(look == .dimmed ? 0.45 : 1)
    }

    var borderColor: Color {
        switch look {
        case .selected: return accent
        case .related: return accent.opacity(0.55)
        case .match: return .orange
        case .normal, .dimmed: return DS.Palette.separator
        }
    }

    var borderWidth: CGFloat {
        switch look {
        case .selected, .match: return 2
        case .related: return 1.25
        case .normal, .dimmed: return 0.5
        }
    }
}

enum ERDrawing {
    struct Curve {
        var start: CGPoint
        var end: CGPoint
        var c1: CGPoint
        var c2: CGPoint
        /// +1 when the line leaves the box to the right.
        var startDir: CGFloat
        var endDir: CGFloat
    }

    /// Bezier from the FK column (child) to the referenced column (parent), choosing the facing sides.
    static func curve(child cf: CGRect, childY: CGFloat, parent pf: CGRect, parentY: CGFloat, selfLoop: Bool) -> Curve {
        let start: CGPoint, end: CGPoint, sd: CGFloat, ed: CGFloat
        if selfLoop {
            start = CGPoint(x: cf.maxX, y: childY); end = CGPoint(x: cf.maxX, y: parentY); sd = 1; ed = 1
        } else if pf.maxX + 24 <= cf.minX {
            start = CGPoint(x: cf.minX, y: childY); end = CGPoint(x: pf.maxX, y: parentY); sd = -1; ed = 1
        } else if cf.maxX + 24 <= pf.minX {
            start = CGPoint(x: cf.maxX, y: childY); end = CGPoint(x: pf.minX, y: parentY); sd = 1; ed = -1
        } else {
            // Overlapping horizontally: loop around the right side.
            start = CGPoint(x: cf.maxX, y: childY); end = CGPoint(x: pf.maxX, y: parentY); sd = 1; ed = 1
        }
        let dx = abs(end.x - start.x)
        let d: CGFloat = (sd == ed) ? max(40, dx * 0.5 + 40) : max(30, dx * 0.45)
        return Curve(start: start, end: end, c1: CGPoint(x: start.x + sd * d, y: start.y), c2: CGPoint(x: end.x + ed * d, y: end.y),
                     startDir: sd, endDir: ed)
    }

    static func edges(in ctx: inout GraphicsContext, state: ERContentState, origin: CGPoint, accent: Color) {
        let byName = Dictionary(state.tables.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let base = Color(nsColor: .secondaryLabelColor)
        var normal = Path(), normalMarks = Path()
        var dimmed = Path(), dimmedMarks = Path()
        var hot = Path(), hotMarks = Path()
        for e in state.edges {
            guard let ct = byName[e.child], let pt = byName[e.parent],
                  let cp = state.positions[e.child], let pp = state.positions[e.parent] else { continue }
            let cf = CGRect(origin: CGPoint(x: cp.x - origin.x, y: cp.y - origin.y), size: ct.size(state.mode))
            let pf = CGRect(origin: CGPoint(x: pp.x - origin.x, y: pp.y - origin.y), size: pt.size(state.mode))
            let c = curve(child: cf, childY: cf.minY + ct.anchorY(column: e.childColumn, mode: state.mode),
                          parent: pf, parentY: pf.minY + pt.anchorY(column: e.parentColumn, mode: state.mode),
                          selfLoop: e.child == e.parent)
            var p = Path()
            p.move(to: c.start)
            p.addCurve(to: c.end, control1: c.c1, control2: c.c2)
            var m = Path()
            // Crow's foot ("many") at the foreign key side.
            let fx = c.start.x + c.startDir * 10
            m.move(to: CGPoint(x: fx, y: c.start.y)); m.addLine(to: CGPoint(x: c.start.x, y: c.start.y - 5))
            m.move(to: CGPoint(x: fx, y: c.start.y)); m.addLine(to: CGPoint(x: c.start.x, y: c.start.y + 5))
            m.move(to: CGPoint(x: fx, y: c.start.y)); m.addLine(to: c.start)
            // Arrow + bar ("one") at the referenced side.
            let ax = c.end.x + c.endDir * 8
            m.move(to: CGPoint(x: ax, y: c.end.y - 4)); m.addLine(to: c.end); m.addLine(to: CGPoint(x: ax, y: c.end.y + 4))
            m.move(to: CGPoint(x: c.end.x + c.endDir * 12, y: c.end.y - 5)); m.addLine(to: CGPoint(x: c.end.x + c.endDir * 12, y: c.end.y + 5))

            let involved = state.selection != nil && (e.child == state.selection || e.parent == state.selection)
            if involved {
                hot.addPath(p); hotMarks.addPath(m)
            } else if state.selection != nil {
                dimmed.addPath(p); dimmedMarks.addPath(m)
            } else {
                normal.addPath(p); normalMarks.addPath(m)
            }
        }
        let style = StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round)
        ctx.stroke(dimmed, with: .color(base.opacity(0.18)), style: style)
        ctx.stroke(dimmedMarks, with: .color(base.opacity(0.18)), style: style)
        ctx.stroke(normal, with: .color(base.opacity(0.6)), style: style)
        ctx.stroke(normalMarks, with: .color(base.opacity(0.6)), style: style)
        let hotStyle = StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
        ctx.stroke(hot, with: .color(accent), style: hotStyle)
        ctx.stroke(hotMarks, with: .color(accent), style: hotStyle)
    }
}

/// Static rendering of the whole diagram for PNG export.
struct ERExportView: View {
    let state: ERContentState
    let accent: Color

    var body: some View {
        let b = state.bounds
        ERContentLayer(state: state, origin: b.origin, accent: accent, model: nil)
            .frame(width: b.width, height: b.height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}
