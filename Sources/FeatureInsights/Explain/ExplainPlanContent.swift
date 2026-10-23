import MTPCore
import MTPUIKit
import SwiftUI

struct ExplainPlanContent: View {
    @ObservedObject var model: ExplainPlanModel

    var body: some View {
        VStack(spacing: 0) {
            ExplainToolbar(model: model)
            VStack(alignment: .leading, spacing: DS.Space.m) {
                SQLSnippet(text: InsightsFormat.oneLine(model.statement, limit: 600), lineLimit: 2)
                if model.analyzeExecutesWrite {
                    Banner(.warning, "ANALYZE executes this \(model.analysis.verb.isEmpty ? "statement" : model.analysis.verb). TableExtra runs it inside BEGIN … ROLLBACK on a separate connection: rows are not changed, but triggers fire, locks are taken while it runs and sequences advance.")
                }
                if let error = model.error { Banner(.error, error) }
                if let plan = model.plan, model.isPostgres { PlanSummary(plan: plan, rolledBack: model.shownRolledBack) }
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, DS.Space.m + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            if model.showText {
                CodeView(model.textPlan ?? (model.isRunning ? "-- Running EXPLAIN…" : ""))
            } else {
                ScrollView {
                    Group {
                        if let plan = model.plan, model.isPostgres {
                            PlanTreeView(model: model, plan: plan)
                        } else if let nodes = model.sqlitePlan {
                            SQLitePlanTreeView(nodes: nodes)
                        } else if model.isRunning {
                            HStack(spacing: DS.Space.s) {
                                ProgressView().controlSize(.small)
                                Text("Running EXPLAIN…").foregroundStyle(.secondary)
                            }
                            .font(DS.Typo.callout)
                            .padding(DS.Space.xl)
                        }
                    }
                    .padding(.horizontal, DS.Space.s)
                    .padding(.vertical, DS.Space.s)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// Lives inside a query tab's result pane, which already names the tab: no title, just the controls.
struct ExplainToolbar: View {
    @ObservedObject var model: ExplainPlanModel

    var body: some View {
        ToolStrip {
            CompactSegmented([(label: "Tree", value: false), (label: "Text", value: true)], selection: $model.showText)
                .padding(.trailing, DS.Space.s)
            if model.isPostgres {
                ToggleChip(title: "ANALYZE", systemImage: "stopwatch", isOn: $model.analyze,
                           help: model.isWrite ? "Executes the statement inside BEGIN … ROLLBACK" : "Executes the query to report actual rows and timings")
            } else {
                Text("EXPLAIN QUERY PLAN").font(DS.Typo.eyebrow).tracking(0.6).foregroundStyle(.secondary).fixedSize()
            }
        } trailing: {
            AskClaudeMenu(context: model.context, items: [
                AskClaudeItem("Why Is It Slow?", systemImage: "tortoise", disabledReason: model.plan == nil && model.sqlitePlan == nil ? "Run the plan first" : nil) {
                    AIRequest(title: "Explain plan", prompt: """
                        Read this execution plan and explain where the time goes and why (scans, misestimates, sorts, loops). \
                        Then give the fix: indexes and/or a rewritten query, in one ```sql block.
                        """, attachments: [AIAttachments.sql(model.statement, title: "Query"),
                                           AIAttachments.text(model.textPlan ?? model.json ?? "", title: model.shownWithAnalyze ? "Plan (ANALYZE)" : "Plan", systemImage: "list.bullet.indent")],
                        focus: model.statement)
                },
                AskClaudeItem("Explain the Plan Simply", systemImage: "text.book.closed", disabledReason: model.plan == nil && model.sqlitePlan == nil ? "Run the plan first" : nil) {
                    AIRequest(title: "Plan in plain words", prompt: "Explain this plan step by step in plain language, from the innermost node to the result.",
                              attachments: [AIAttachments.sql(model.statement, title: "Query"),
                                            AIAttachments.text(model.textPlan ?? model.json ?? "", title: "Plan", systemImage: "list.bullet.indent")],
                              focus: model.statement)
                },
            ])
            if model.isRunning {
                ProgressView().controlSize(.mini)
                ToolButton("Cancel", systemImage: "stop.fill") { model.cancel() }
            } else if let d = model.lastDuration {
                Text(Fmt.duration(d)).font(DS.Typo.caption).monospacedDigit().foregroundStyle(.secondary).fixedSize()
                    .help("EXPLAIN ran in \(Fmt.duration(d))")
                    .padding(.trailing, DS.Space.xs)
            }
            ToolButton("Re-run", systemImage: "arrow.clockwise") { model.rerun() }
                .disabled(model.isRunning)
            ToolButton(model.showText ? "Copy Text" : "Copy JSON", systemImage: "doc.on.doc") {
                if let text = model.copyText { Pasteboard.copy(text) }
            }
            .disabled(model.copyText == nil)
        }
    }
}

struct PlanSummary: View {
    var plan: ExplainPlan
    var rolledBack: Bool

    var body: some View {
        HStack(spacing: DS.Space.xxl) {
            metric("Planning", InsightsFormat.ms(plan.planningTime))
            if plan.isAnalyze { metric("Execution", InsightsFormat.ms(plan.executionTime)) }
            metric("Total cost", InsightsFormat.cost(plan.totalCost))
            if plan.isAnalyze, let rows = plan.root.actualRows {
                metric("Rows", "\(InsightsFormat.count(rows)) of \(InsightsFormat.count(plan.root.planRows)) est.")
            } else {
                metric("Est. rows", InsightsFormat.count(plan.root.planRows))
            }
            if let hit = plan.root.sharedHitBlocks {
                metric("Buffers", "hit \(InsightsFormat.count(hit)) · read \(InsightsFormat.count(plan.root.sharedReadBlocks))")
            }
            if !plan.triggers.isEmpty {
                metric("Triggers", plan.triggers.map { "\($0.name) \(InsightsFormat.ms($0.time))" }.joined(separator: ", "))
            }
            if let jit = plan.jitTime { metric("JIT", "\(InsightsFormat.ms(jit)) · \(plan.jitFunctions ?? 0) functions") }
            if rolledBack { Tag("rolled back", tone: .warning) }
            Spacer(minLength: 0)
        }
        .help(plan.settings.isEmpty ? "" : "Settings: " + plan.settings.map { "\($0.label) = \($0.value)" }.joined(separator: ", "))
    }

    func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            Text(title.uppercased()).font(DS.Typo.eyebrow).tracking(0.5).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(DS.Typo.body.weight(.semibold)).monospacedDigit().lineLimit(1)
        }
        .fixedSize()
    }
}

struct PlanTreeView: View {
    @ObservedObject var model: ExplainPlanModel
    var plan: ExplainPlan

    var body: some View {
        let hottest = plan.mostExpensiveNodeID
        VStack(alignment: .leading, spacing: 0) {
            if !plan.settings.isEmpty {
                Text("Settings: " + plan.settings.map { "\($0.label) = \($0.value)" }.joined(separator: ", "))
                    .font(DS.Typo.caption).foregroundStyle(.secondary).padding(.horizontal, DS.Space.s).padding(.bottom, DS.Space.s)
            }
            ForEach(model.visibleNodes(plan)) { node in
                PlanNodeRow(node: node, plan: plan, isHottest: node.id == hottest && plan.nodes.count > 1,
                            showDetails: model.expanded.contains(node.id), isCollapsed: model.collapsed.contains(node.id),
                            toggleDetails: { model.toggleDetails(node.id) }, toggleCollapsed: { model.toggleCollapsed(node.id) })
                Divider().opacity(0.6)
            }
        }
    }
}

struct PlanNodeRow: View {
    var node: PlanNode
    var plan: ExplainPlan
    var isHottest: Bool
    var showDetails: Bool
    var isCollapsed: Bool
    var toggleDetails: () -> Void
    var toggleCollapsed: () -> Void

    static let indent: CGFloat = 18

    var body: some View {
        let share = plan.share(of: node)
        HStack(alignment: .top, spacing: 0) {
            ForEach(0..<node.depth, id: \.self) { _ in
                Rectangle().fill(DS.Palette.separator).frame(width: 0.5).padding(.trailing, Self.indent - 0.5)
            }
            Group {
                if node.children.isEmpty {
                    Image(systemName: "circle.fill").font(.system(size: 4)).foregroundStyle(.tertiary)
                } else {
                    Button(action: toggleCollapsed) {
                        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down").font(.caption2.weight(.bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(isCollapsed ? "Show children" : "Hide children")
                }
            }
            .frame(width: 16, height: 18)
            VStack(alignment: .leading, spacing: 3) {
                titleLine(share)
                metricsLine
                ForEach(node.conditions, id: \.self) { c in
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(c.label + ":").font(DS.Typo.caption).foregroundStyle(.secondary)
                        Text(c.value)
                            .font(DS.Typo.monoSmall)
                            .foregroundStyle(c.label.hasPrefix("Rows Removed") ? Color(nsColor: NSColor.systemOrange.readableText()) : Color.primary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if showDetails { details }
            }
            .padding(.leading, 2)
        }
        .padding(.vertical, DS.Space.s + 1)
        .padding(.horizontal, DS.Space.m)
        .background(isHottest ? Color(nsColor: NSColor.systemOrange.softFill()).opacity(0.6) : Color.clear)
        .overlay(alignment: .leading) {
            if isHottest { Rectangle().fill(Color.orange).frame(width: 2) }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: toggleDetails)
    }

    func titleLine(_ share: Double) -> some View {
        HStack(spacing: 6) {
            if let sub = node.subplanName {
                Text(sub).font(DS.Typo.caption).foregroundStyle(.secondary)
            } else if let rel = node.parentRelationship, ["InitPlan", "SubPlan"].contains(rel) {
                Text(rel).font(DS.Typo.caption).foregroundStyle(.secondary)
            }
            Text(node.displayName).font(DS.Typo.headline)
            if let target = node.targetDescription {
                Text(target).font(DS.Typo.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            if isHottest { Tag(plan.isAnalyze ? "slowest" : "most expensive", tone: .critical) }
            if let f = node.misestimateFactor, f >= 10 {
                Tag("\(node.isUnderestimated ? "↑" : "↓")\(InsightsFormat.compact(f))× rows", tone: .warning)
                    .help("Estimated \(InsightsFormat.count(node.planRows)) rows, got \(InsightsFormat.count(node.actualRows)) per loop: \(node.isUnderestimated ? "under" : "over")-estimated \(String(format: "%.0f", f))×. Run ANALYZE on the table or add extended statistics.")
            }
            if plan.isAnalyze && !node.wasExecuted { Tag("never executed", tone: .neutral) }
            if (node.tempWrittenBlocks ?? 0) > 0 { Tag("temp \(InsightsFormat.count(node.tempWrittenBlocks)) blocks", tone: .warning) }
            Spacer(minLength: 8)
            Meter(fraction: share, tone: share > 0.5 ? .critical : share > 0.2 ? .warning : .neutral)
                .frame(width: 80, height: 4)
            Text(InsightsFormat.percent(share, digits: 0)).font(DS.Typo.caption).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
            Text(plan.isAnalyze ? InsightsFormat.ms(node.exclusiveTime) : InsightsFormat.cost(node.exclusiveCost))
                .font(DS.Typo.callout.weight(.medium)).monospacedDigit()
                .frame(width: 78, alignment: .trailing)
                .help(plan.isAnalyze ? "Time spent in this node alone (all loops)" : "Cost of this node alone")
        }
    }

    var metricsLine: some View {
        var parts = ["cost \(InsightsFormat.cost(node.startupCost))..\(InsightsFormat.cost(node.totalCost))"]
        if let actual = node.actualRows {
            parts.append("rows \(InsightsFormat.count(node.planRows)) est → \(InsightsFormat.count(actual)) actual")
        } else {
            parts.append("rows \(InsightsFormat.count(node.planRows)) est")
        }
        if let loops = node.actualLoops, loops != 1 { parts.append("\(InsightsFormat.count(loops)) loops") }
        if let t = node.actualTotalTime {
            parts.append("time \(InsightsFormat.ms(node.actualStartupTime))..\(InsightsFormat.ms(t))" + ((node.actualLoops ?? 1) > 1 ? " per loop" : ""))
        }
        if let w = node.workersLaunched ?? node.workersPlanned { parts.append("\(w) workers") }
        if node.sharedHitBlocks != nil || node.sharedReadBlocks != nil {
            parts.append("buffers hit \(InsightsFormat.count(node.sharedHitBlocks)) read \(InsightsFormat.count(node.sharedReadBlocks))")
        }
        return Text(parts.joined(separator: " · "))
            .font(DS.Typo.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }

    var details: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !node.output.isEmpty {
                detailLine("Output", node.output.joined(separator: ", "))
            }
            // Zero block counters (Local …, I/O timings off) are noise.
            ForEach(node.properties.filter { !($0.label.hasSuffix("Blocks") && $0.value == "0") }, id: \.self) { p in
                detailLine(p.label, p.value)
            }
            if let d = node.sharedDirtiedBlocks, d > 0 { detailLine("Shared Dirtied Blocks", InsightsFormat.count(d)) }
            if let w = node.sharedWrittenBlocks, w > 0 { detailLine("Shared Written Blocks", InsightsFormat.count(w)) }
            if let r = node.tempReadBlocks, r > 0 { detailLine("Temp Read Blocks", InsightsFormat.count(r)) }
        }
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).fill(DS.Palette.canvas))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).strokeBorder(DS.Palette.separator.opacity(0.7), lineWidth: 0.5))
        .padding(.top, DS.Space.xs)
    }

    func detailLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(label + ":").font(DS.Typo.caption).foregroundStyle(.secondary)
            Text(value).font(DS.Typo.monoSmall).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SQLitePlanTreeView: View {
    var nodes: [SQLiteQueryPlanNode]

    var body: some View {
        let all = nodes.flatMap(\.flattened)
        VStack(alignment: .leading, spacing: 0) {
            if all.isEmpty {
                EmptyFinding(text: "EXPLAIN QUERY PLAN returned no rows.", systemImage: "tray", tone: .neutral)
            }
            ForEach(all) { n in
                HStack(spacing: 0) {
                    ForEach(0..<n.depth, id: \.self) { _ in
                        Rectangle().fill(DS.Palette.separator).frame(width: 0.5).padding(.trailing, 17.5)
                    }
                    Image(systemName: n.children.isEmpty ? "circle.fill" : "chevron.down")
                        .font(.system(size: n.children.isEmpty ? 4 : 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(n.detail).font(DS.Typo.mono).textSelection(.enabled)
                    if n.isFullScan { Tag("full scan", tone: .warning).padding(.leading, DS.Space.s) }
                    if n.usesTempBTree { Tag("temp B-tree", tone: .warning).padding(.leading, DS.Space.s) }
                    Spacer()
                    Text("#\(n.id)").font(DS.Typo.caption).monospacedDigit().foregroundStyle(.tertiary)
                }
                .padding(.vertical, DS.Space.s)
                .padding(.horizontal, DS.Space.m)
                .background(n.isFullScan ? Color(nsColor: NSColor.systemOrange.softFill()).opacity(0.5) : Color.clear)
                Divider().opacity(0.6)
            }
        }
    }
}
