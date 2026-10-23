import MTPCore
import MTPUIKit
import SwiftUI

/// Scroll targets of the dashboard sections.
enum DashboardAnchor: String {
    case overview, locks, longTransactions, slowQueries, tables, indexes, vacuum, sequences
}

/// One line of key figures under the header (Supabase "8 Slow Queries / 99.98% Cache Hit Rate / …").
/// Each figure scrolls to its section when `scrollTo` is set.
struct DashboardHeadline: View {
    @ObservedObject var model: InsightsDashboardModel
    var scrollTo: ((DashboardAnchor) -> Void)?

    struct Figure: Identifiable {
        var value: String
        var label: String
        var tone: Tone = .neutral
        var anchor: DashboardAnchor
        var help: String
        var id: String { label }
    }

    var body: some View {
        let items = figures
        // Wide: one line with slashes. Narrow: the same figures with labels under the values.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, f in
                    if i > 0 { slash }
                    button(f) {
                        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                            value(f)
                            label(f)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, f in
                    if i > 0 { divider }
                    button(f) {
                        VStack(alignment: .leading, spacing: DS.Space.xxs) {
                            value(f)
                            label(f)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, DS.Space.xs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Key figures")
    }

    var figures: [Figure] {
        let o = model.overview.value
        let findings = findingCount
        return [
            Figure(value: o.map { "\(InsightsFormat.count($0.connections)) / \(InsightsFormat.count($0.maxConnections))" } ?? "—",
                   label: "Connections", tone: connectionTone(o), anchor: .overview,
                   help: o.map { "\(InsightsFormat.percent($0.connectionUsage)) of max_connections in use" } ?? "Connections in use / max_connections"),
            Figure(value: InsightsFormat.percent(o?.cacheHitRatio, digits: 2), label: "Cache hit rate", tone: cacheTone(o?.cacheHitRatio),
                   anchor: .overview, help: "Share of block reads served from shared buffers"),
            Figure(value: InsightsFormat.bytes(o?.databaseBytes), label: "Database size", anchor: .tables,
                   help: "Size of \(model.databaseName); show the largest tables"),
            Figure(value: findings.map { "\($0.count)" } ?? "—", label: findings?.count == 1 ? "Finding" : "Findings",
                   tone: (findings?.count ?? 0) > 0 ? (findings?.critical == true ? .critical : .warning) : .neutral,
                   anchor: findings?.first ?? .locks,
                   help: "Locks, long transactions, unused or duplicate indexes, vacuum issues and sequences needing attention"),
        ]
    }

    /// Items needing attention across the finding sections, and the first section holding one.
    var findingCount: (count: Int, critical: Bool, first: DashboardAnchor?)? {
        let parts: [(DashboardAnchor, Int?, Bool)] = [
            (.locks, model.blocking.value?.count, true),
            (.longTransactions, model.longTransactions.value?.count, false),
            (.indexes, model.indexes.value.map { $0.unused.count + $0.duplicates.count }, false),
            (.vacuum, model.vacuum.value?.issues.count, false),
            (.sequences, model.sequences.value?.count, true),
        ]
        guard parts.contains(where: { $0.1 != nil }) else { return nil }
        let count = parts.reduce(0) { $0 + ($1.1 ?? 0) }
        let critical = parts.contains { $0.2 && ($0.1 ?? 0) > 0 }
        return (count, critical, parts.first { ($0.1 ?? 0) > 0 }?.0)
    }

    func connectionTone(_ s: OverviewStats?) -> Tone {
        guard let u = s?.connectionUsage else { return .neutral }
        return u > 0.95 ? .critical : u > 0.8 ? .warning : .neutral
    }

    func cacheTone(_ ratio: Double?) -> Tone {
        guard let ratio else { return .neutral }
        return ratio < 0.95 ? .critical : ratio < 0.99 ? .warning : .neutral
    }

    func value(_ f: Figure) -> some View {
        Text(f.value)
            .font(.system(size: 20, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(f.tone == .warning || f.tone == .critical ? Color(nsColor: f.tone.nsColor.readableText()) : Color.primary)
            .lineLimit(1)
            .fixedSize()
    }

    func label(_ f: Figure) -> some View {
        Text(f.label)
            .font(DS.Typo.body)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
    }

    @ViewBuilder
    func button<L: View>(_ f: Figure, @ViewBuilder label: () -> L) -> some View {
        if let scrollTo {
            Button { scrollTo(f.anchor) } label: { label().contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .help(f.help)
        } else {
            label().help(f.help)
        }
    }

    var slash: some View {
        Text("/")
            .font(.system(size: 20, weight: .light))
            .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
            .padding(.horizontal, DS.Space.l)
    }

    var divider: some View {
        Rectangle()
            .fill(DS.Palette.separator)
            .frame(width: 0.5, height: 34)
            .padding(.horizontal, DS.Space.l)
    }
}
