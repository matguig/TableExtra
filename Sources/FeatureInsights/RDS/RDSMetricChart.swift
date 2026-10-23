import Charts
import MTPCore
import MTPUIKit
import SwiftUI

/// One CloudWatch metric: title, latest value, avg / max, area + line chart with unit-aware axis and hover readout.
struct RDSMetricChart: View {
    var title: String
    var unit: RDSMetricUnit
    var points: [RDSMetricPoint]
    var range: RDSTimeRange
    var tint: Color = .accentColor
    /// Fixed y ceiling in raw units (100 for percentages).
    var ceiling: Double?
    /// Pre-set hover position (render tests).
    @State var hover: Date?

    static let chartHeight: CGFloat = 104

    var body: some View {
        let maxRaw = max(points.map(\.value).max() ?? 0, ceiling ?? 0)
        let scale = RDSUnits.scale(for: unit, maxRaw: maxRaw)
        Card(padding: DS.Space.l) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                    Text(title).font(DS.Typo.callout.weight(.medium)).lineLimit(1)
                    Spacer(minLength: DS.Space.s)
                    Text(RDSUnits.format(points.last?.value, unit: unit))
                        .font(.system(size: 15, weight: .semibold)).monospacedDigit().lineLimit(1)
                }
                Text(summary).font(DS.Typo.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                if points.isEmpty {
                    Text("No data points in this range")
                        .font(DS.Typo.caption).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, minHeight: Self.chartHeight)
                } else {
                    chart(scale: scale, top: maxRaw * scale.factor)
                        .frame(height: Self.chartHeight)
                }
            }
        }
    }

    var summary: String {
        guard !points.isEmpty else { return " " }
        let values = points.map(\.value)
        let avg = values.reduce(0, +) / Double(values.count)
        return "avg \(RDSUnits.format(avg, unit: unit)) · max \(RDSUnits.format(values.max(), unit: unit))"
    }

    func chart(scale: RDSUnits.Scale, top: Double) -> some View {
        let upper = ceiling.map { $0 * scale.factor } ?? (top > 0 ? top * 1.15 : 1)
        return Chart {
            ForEach(points, id: \.date) { p in
                AreaMark(x: .value("Time", p.date), y: .value(title, p.value * scale.factor))
                    .foregroundStyle(LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", p.date), y: .value(title, p.value * scale.factor))
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.monotone)
            }
            if let hover, let p = nearest(hover) {
                RuleMark(x: .value("Time", p.date))
                    .foregroundStyle(Color.secondary.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .center, spacing: 2, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        readout(p)
                    }
                PointMark(x: .value("Time", p.date), y: .value(title, p.value * scale.factor))
                    .foregroundStyle(tint)
                    .symbolSize(28)
            }
        }
        .chartYScale(domain: 0...max(upper, 0.000_001))
        .chartXScale(domain: (points.first?.date ?? Date())...(points.last?.date ?? Date()))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(DS.Palette.separator.opacity(0.6))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(RDSUnits.axisLabel(v, suffix: scale.suffix)).font(.system(size: 9)).monospacedDigit()
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(DS.Palette.separator.opacity(0.4))
                AxisValueLabel {
                    if let d = value.as(Date.self) {
                        Text(range == .week ? d.formatted(.dateTime.weekday(.abbreviated).day()) : d.formatted(.dateTime.hour().minute()))
                            .font(.system(size: 9))
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let loc):
                            guard let frame = proxy.plotFrame else { return }
                            hover = proxy.value(atX: loc.x - geo[frame].origin.x)
                        case .ended:
                            hover = nil
                        }
                    }
            }
        }
    }

    func nearest(_ d: Date) -> RDSMetricPoint? {
        points.min { abs($0.date.timeIntervalSince(d)) < abs($1.date.timeIntervalSince(d)) }
    }

    func readout(_ p: RDSMetricPoint) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(p.date.formatted(range == .week ? .dateTime.weekday(.abbreviated).day().hour().minute() : .dateTime.hour().minute()))
                .foregroundStyle(.secondary)
            Text(RDSUnits.format(p.value, unit: unit)).fontWeight(.semibold).monospacedDigit()
        }
        .font(.system(size: 10.5))
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: DS.Radius.s + 1, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.s + 1, style: .continuous).strokeBorder(DS.Palette.separator, lineWidth: 0.5))
        .fixedSize()
    }
}
