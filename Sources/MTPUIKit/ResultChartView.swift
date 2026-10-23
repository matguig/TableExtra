import AppKit
import Charts
import MTPCore
import SwiftUI

/// Chart of a query result (TablePlus "Chart" result tab: x-axis / y-axis pickers, bar / line / pie),
/// with automatic axes, several y columns, a color-by column, aggregation, hover readout and PNG export.
public struct ResultChartView: View {
    var result: QueryResult
    @Binding var config: ChartConfig
    @State private var hoverX: ChartX?

    public init(result: QueryResult, config: Binding<ChartConfig>) {
        self.result = result
        self._config = config
    }

    private var data: ChartData { ChartData.build(result, config: config) }

    public var body: some View {
        let data = data
        VStack(spacing: 0) {
            controls
            Group {
                if !config.isComplete {
                    EmptyState("Pick what to plot", systemImage: "chart.bar.xaxis",
                               message: "Choose an x-axis column and at least one numeric y-axis column, or count rows per x value.") {
                        Button("Suggest Axes") { config = ChartData.suggest(for: result) }
                    }
                } else if data.points.isEmpty {
                    EmptyState("Nothing to plot", systemImage: "chart.bar.xaxis",
                               message: "The selected y columns have no numeric values in this result.")
                } else {
                    chart(data)
                        .padding(.horizontal, DS.Space.xl)
                        .padding(.vertical, DS.Space.l)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            StatusBar {
                Text("\(data.points.count) point\(data.points.count == 1 ? "" : "s")").monospacedDigit()
                if data.series.count > 1 { Text("\(data.series.count) series") }
                if data.skippedRows > 0 { Text("\(data.skippedRows) rows skipped (NULL or not numeric)").foregroundStyle(.orange) }
                if data.truncated { Text("first \(Fmt.count(Int64(ChartData.maxRows))) rows").foregroundStyle(.orange) }
            } trailing: {
                if let hoverX { Text(hoverX.label).monospacedDigit() }
            }
        }
    }

    // MARK: Controls

    private var numericColumns: [ResultColumn] { result.columns.filter(\.isNumeric) }

    private var controls: some View {
        ToolStrip {
            CompactSegmented(ChartKind.allCases.map { (label: $0.title, value: $0) }, selection: $config.kind)
                .padding(.trailing, DS.Space.s)
            axisMenu(title: "X", value: config.x ?? "Choose…") {
                ForEach(result.columns, id: \.name) { c in
                    Button { config.x = c.name } label: { check(c.name == config.x, "\(c.name)  \(c.typeName)") }
                }
            }
            axisMenu(title: config.kind == .pie ? "Value" : "Y", value: yTitle) {
                ForEach(numericColumns, id: \.name) { c in
                    Button {
                        if let i = config.ys.firstIndex(of: c.name) { config.ys.remove(at: i) }
                        else if config.kind == .pie { config.ys = [c.name] }
                        else { config.ys.append(c.name) }
                        if config.aggregate == .count && !config.ys.isEmpty { config.aggregate = .none }
                    } label: { check(config.ys.contains(c.name), "\(c.name)  \(c.typeName)") }
                }
                if numericColumns.isEmpty { Text("No numeric column in this result") }
            }
            if config.kind != .pie {
                axisMenu(title: "Color", value: config.series ?? "None") {
                    Button { config.series = nil } label: { check(config.series == nil, "None") }
                    Divider()
                    ForEach(result.columns.filter { !$0.isNumeric && $0.name != config.x }, id: \.name) { c in
                        Button { config.series = c.name } label: { check(config.series == c.name, c.name) }
                    }
                }
            }
            axisMenu(title: "Aggregate", value: config.aggregate == .none ? "None" : config.aggregate.title) {
                ForEach(ChartAggregate.allCases) { a in
                    Button { config.aggregate = a } label: { check(config.aggregate == a, a.title) }
                }
            }
        } trailing: {
            ToolButton("Reset", systemImage: "arrow.counterclockwise", help: "Suggest axes again") {
                config = ChartData.suggest(for: result)
            }
            Menu {
                Button("Copy Image") { copyImage() }
                Button("Save PNG…") { savePNG() }
            } label: {
                Image(systemName: "square.and.arrow.up").font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(!config.isComplete)
            .help("Export chart")
        }
    }

    private var yTitle: String {
        if config.ys.isEmpty { return config.aggregate == .count ? "Row count" : "Choose…" }
        if config.kind == .pie { return config.ys[0] }
        return config.ys.count == 1 ? config.ys[0] : "\(config.ys.count) columns"
    }

    @ViewBuilder
    private func check(_ on: Bool, _ title: String) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    private func axisMenu<Content: View>(title: String, value: String, @ViewBuilder content: () -> Content) -> some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Text(value).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 7.5, weight: .bold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).fill(Color.primary.opacity(0.06)))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: Chart

    @ViewBuilder
    private func chart(_ data: ChartData) -> some View {
        if config.kind == .pie {
            pie(data)
        } else {
            Chart {
                ForEach(data.points) { p in mark(p, data: data) }
                if let hoverX { hoverRule(hoverX, data: data) }
            }
            .chartLegend(data.series.count > 1 ? .visible : .hidden)
            .chartLegend(position: .top, alignment: .leading)
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let loc):
                                guard let frame = proxy.plotFrame else { return }
                                let x = loc.x - geo[frame].origin.x
                                hoverX = nearestX(to: x, proxy: proxy, data: data)
                            case .ended:
                                hoverX = nil
                            }
                        }
                }
            }
        }
    }

    /// Axis type used for x: bars are always categorical; other marks follow the column (date, number, text).
    private func axis(_ data: ChartData) -> ChartXKind { config.kind == .bar ? .text : data.xKind }

    @ChartContentBuilder
    private func mark(_ p: ChartPoint, data: ChartData) -> some ChartContent {
        let series = PlottableValue.value("Series", p.series)
        let y = PlottableValue.value("Value", p.value)
        switch (config.kind, axis(data)) {
        case (.bar, _):
            if data.series.count > 1 {
                BarMark(x: .value("X", p.x.label), y: y)
                    .foregroundStyle(by: series)
                    .position(by: .value("Series", p.series))
                    .cornerRadius(3)
            } else {
                BarMark(x: .value("X", p.x.label), y: y)
                    .foregroundStyle(Color.accentColor.gradient)
                    .cornerRadius(3)
                    .opacity(hoverX == nil || hoverX == p.x ? 1 : 0.55)
            }
        case (.line, .date):
            LineMark(x: .value("X", Self.date(p.x)), y: y).foregroundStyle(by: series).interpolationMethod(.monotone)
                .symbol(by: series).symbolSize(data.points.count > 200 ? 0 : 20)
        case (.line, .number):
            LineMark(x: .value("X", Self.number(p.x)), y: y).foregroundStyle(by: series).interpolationMethod(.monotone)
                .symbol(by: series).symbolSize(data.points.count > 200 ? 0 : 20)
        case (.line, .text):
            LineMark(x: .value("X", p.x.label), y: y).foregroundStyle(by: series).interpolationMethod(.monotone)
                .symbol(by: series).symbolSize(data.points.count > 200 ? 0 : 20)
        case (.area, .date):
            AreaMark(x: .value("X", Self.date(p.x)), y: y).foregroundStyle(by: series).interpolationMethod(.monotone).opacity(0.75)
        case (.area, .number):
            AreaMark(x: .value("X", Self.number(p.x)), y: y).foregroundStyle(by: series).interpolationMethod(.monotone).opacity(0.75)
        case (.area, .text):
            AreaMark(x: .value("X", p.x.label), y: y).foregroundStyle(by: series).interpolationMethod(.monotone).opacity(0.75)
        case (_, .date):
            PointMark(x: .value("X", Self.date(p.x)), y: y).foregroundStyle(by: series).symbolSize(30)
        case (_, .number):
            PointMark(x: .value("X", Self.number(p.x)), y: y).foregroundStyle(by: series).symbolSize(30)
        case (_, .text):
            PointMark(x: .value("X", p.x.label), y: y).foregroundStyle(by: series).symbolSize(30)
        }
    }

    @ChartContentBuilder
    private func hoverRule(_ x: ChartX, data: ChartData) -> some ChartContent {
        switch axis(data) {
        case .date: RuleMark(x: .value("X", Self.date(x))).foregroundStyle(Color.secondary.opacity(0.4)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .annotation(position: .top, alignment: .center, spacing: 4) { readout(x, data: data) }
        case .number: RuleMark(x: .value("X", Self.number(x))).foregroundStyle(Color.secondary.opacity(0.4)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .annotation(position: .top, alignment: .center, spacing: 4) { readout(x, data: data) }
        case .text: RuleMark(x: .value("X", x.label)).foregroundStyle(Color.secondary.opacity(0.4)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .annotation(position: .top, alignment: .center, spacing: 4) { readout(x, data: data) }
        }
    }

    static func date(_ x: ChartX) -> Date {
        if case .date(let d) = x { return d }
        return .distantPast
    }

    static func number(_ x: ChartX) -> Double {
        if case .number(let v) = x { return v }
        return 0
    }

    private func pie(_ data: ChartData) -> some View {
        let total = data.points.reduce(0) { $0 + $1.value }
        return HStack(spacing: DS.Space.xxl) {
            Chart(data.points) { p in
                SectorMark(angle: .value("Value", p.value), innerRadius: .ratio(0.55), angularInset: 1.5)
                    .foregroundStyle(by: .value("Category", p.x.label))
                    .cornerRadius(3)
            }
            .chartLegend(.hidden)
            .frame(minWidth: 220, maxWidth: 420)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                VStack(spacing: 2) {
                    Text(Self.format(total)).font(.system(size: 20, weight: .semibold)).monospacedDigit()
                    Text(config.ys.first ?? "rows").font(DS.Typo.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(data.points.enumerated()), id: \.offset) { i, p in
                    HStack(spacing: DS.Space.s) {
                        Circle().fill(Self.palette[i % Self.palette.count]).frame(width: 8, height: 8)
                        Text(p.x.label).font(DS.Typo.callout).lineLimit(1)
                        Spacer(minLength: DS.Space.l)
                        Text(Self.format(p.value)).font(DS.Typo.monoSmall).monospacedDigit()
                        Text(total > 0 ? String(format: "%.1f%%", p.value / total * 100) : "").font(DS.Typo.caption)
                            .foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)
                    }
                }
            }
            .frame(maxWidth: 320)
        }
        .chartForegroundStyleScale(range: Self.palette)
    }

    /// Default Swift Charts categorical order, so pie legend dots match the sectors.
    static let palette: [Color] = [.blue, .green, .orange, .purple, .red, .teal, .yellow, .pink, .brown, .indigo, .mint, .gray]

    private func readout(_ x: ChartX, data: ChartData) -> some View {
        let rows = data.points.filter { $0.x == x }
        return VStack(alignment: .leading, spacing: 3) {
            Text(x.label).font(.system(size: 11, weight: .semibold))
            ForEach(Array(rows.prefix(8).enumerated()), id: \.offset) { _, p in
                HStack(spacing: 6) {
                    if data.series.count > 1 { Text(p.series).foregroundStyle(.secondary) }
                    Spacer(minLength: 8)
                    Text(Self.format(p.value)).monospacedDigit()
                }
                .font(.system(size: 11))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).strokeBorder(DS.Palette.separator, lineWidth: 0.5))
        .fixedSize()
    }

    private func nearestX(to px: CGFloat, proxy: ChartProxy, data: ChartData) -> ChartX? {
        let xs = Array(Set(data.points.map(\.x)))
        switch axis(data) {
        case .date:
            guard let d: Date = proxy.value(atX: px) else { return nil }
            return xs.min { abs(Self.date($0).timeIntervalSince(d)) < abs(Self.date($1).timeIntervalSince(d)) }
        case .number:
            guard let v: Double = proxy.value(atX: px) else { return nil }
            return xs.min { abs(Self.number($0) - v) < abs(Self.number($1) - v) }
        case .text:
            guard let label: String = proxy.value(atX: px) else { return nil }
            return xs.first { $0.label == label }
        }
    }

    static func format(_ v: Double) -> String {
        if abs(v) >= 1_000_000 { return String(format: "%.2fM", v / 1_000_000) }
        if v.rounded() == v, abs(v) < 1e12 { return Fmt.count(Int64(v)) }
        return String(format: "%.2f", v)
    }

    // MARK: Export

    @MainActor
    private func renderImage() -> NSImage? {
        let content = chart(data)
            .padding(24)
            .frame(width: 1200, height: 700)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        return renderer.nsImage
    }

    @MainActor
    private func copyImage() {
        guard let image = renderImage() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    @MainActor
    private func savePNG() {
        guard let image = renderImage(), let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "chart.png"
        if panel.runModal() == .OK, let url = panel.url { try? png.write(to: url) }
    }
}
