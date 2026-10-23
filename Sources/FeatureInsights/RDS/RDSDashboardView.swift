import Charts
import MTPCore
import MTPUIKit
import SwiftUI

/// AWS RDS / Aurora monitoring for the connection: configuration, warnings, CloudWatch charts, Performance Insights, events.
/// Read-only, through the AWS SDK with the user's profiles (`context.connection.effectiveAWS`).
public struct RDSDashboardView: View {
    @StateObject private var model: RDSDashboardModel

    public init(context: WorkspaceContext) {
        _model = StateObject(wrappedValue: RDSDashboardModel(context: context))
    }

    public var body: some View {
        RDSDashboardContent(model: model)
            .onAppear { model.start() }
            .onDisappear { model.stop() }
    }
}

struct RDSDashboardContent: View {
    @ObservedObject var model: RDSDashboardModel

    var body: some View {
        VStack(spacing: 0) {
            RDSHeader(model: model)
            if model.settings == nil {
                RDSNotConfiguredView(connection: model.context.connection)
            } else if let setupError = model.setupError {
                RDSSetupErrorView(error: setupError, grant: model.grantAWSAccess)
            } else {
                ScrollView {
                    RDSDashboardSections(model: model)
                        .padding(DS.Space.xl)
                        .frame(maxWidth: 1280)
                        .frame(maxWidth: .infinity)
                }
                StatusBar {
                    Text("Read-only · AWS SDK")
                    if let p = model.settings?.profile, !p.isEmpty { Text("profile \(p)") }
                } trailing: {
                    if model.isRefreshing {
                        Text("Loading…")
                    } else if let last = model.lastRefresh {
                        Text("Updated \(last.formatted(date: .omitted, time: .standard))").monospacedDigit()
                    }
                }
            }
        }
        .background(DS.Palette.canvas)
    }
}

struct RDSHeader: View {
    @ObservedObject var model: RDSDashboardModel

    var body: some View {
        PaneHeader("AWS RDS", subtitle: model.subtitle, systemImage: "cloud", tint: .orange) {
            if model.settings != nil && model.setupError == nil {
                HStack(spacing: DS.Space.xs) {
                    if model.isRefreshing { ProgressView().controlSize(.small).padding(.trailing, DS.Space.xs) }
                    if let cluster = model.overview.value?.cluster, cluster.members.count > 1 { memberMenu(cluster) }
                    CompactSegmented(RDSTimeRange.allCases.map { (label: $0.title, value: $0) }, selection: $model.range)
                        .padding(.horizontal, DS.Space.xs)
                    AskClaudeMenu(context: model.context, items: model.claudeItems)
                    ToolButton("Refresh", systemImage: "arrow.clockwise") { model.reload(full: true) }
                }
            }
        }
    }

    func memberMenu(_ cluster: RDSClusterInfo) -> some View {
        let current = model.selectedMember ?? cluster.writer ?? "?"
        return Menu {
            ForEach(cluster.members) { m in
                Button {
                    model.selectedMember = m.isWriter ? nil : m.identifier
                } label: {
                    let cls = model.overview.value?.instances.first { $0.identifier == m.identifier }?.instanceClass ?? ""
                    let title = "\(m.identifier)  \(m.isWriter ? "writer" : "reader")  \(cls)"
                    if m.identifier == current { Label(title, systemImage: "checkmark") } else { Text(title) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "server.rack").font(.system(size: 10.5))
                Text(current).font(.system(size: 12)).lineLimit(1)
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
        .help("Cluster member whose metrics and Performance Insights are shown")
    }
}

struct RDSNotConfiguredView: View {
    var connection: ConnectionConfig

    var body: some View {
        EmptyState("AWS is not set up for this connection", systemImage: "cloud",
                   message: message)
    }

    var message: String {
        if connection.aws?.isEnabled == false {
            return "RDS monitoring is turned off in this connection's settings (AWS section)."
        }
        return "Open the connection settings and fill in the AWS section: profile, region and DB instance (or Aurora cluster) identifier. "
            + "TableExtra reads RDS, CloudWatch and Performance Insights read-only with your AWS profiles."
    }
}

/// The AWS clients could not be created: most often the AWS folder was never granted.
struct RDSSetupErrorView: View {
    var error: AWSError
    var grant: () -> Void

    var body: some View {
        if error == .noConfigAccess {
            EmptyState("Allow access to your AWS profiles", systemImage: "key.horizontal",
                       message: "TableExtra reads your profiles and credentials from your AWS folder (usually ~/.aws), read-only, "
                           + "and only after you select it. Nothing is written there and no keys are copied.") {
                Button("Allow Access to ~/.aws…", action: grant).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        } else {
            EmptyState("AWS is not reachable", systemImage: "exclamationmark.triangle", message: error.localizedDescription)
        }
    }
}

/// Every section stacked; rendered without the ScrollView in snapshot tests.
struct RDSDashboardSections: View {
    @ObservedObject var model: RDSDashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xxl) {
            RDSHeadline(model: model).padding(.bottom, -DS.Space.xs)
            let warnings = model.warnings
            if !warnings.isEmpty {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    ForEach(warnings) { w in Banner(w.severity == .critical ? .error : w.severity == .warning ? .warning : .info, w.text) }
                }
            }
            RDSConfigurationSection(model: model)
            RDSMetricsSection(model: model)
            RDSInsightsSection(model: model)
            RDSEventsSection(model: model)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Headline

struct RDSHeadline: View {
    @ObservedObject var model: RDSDashboardModel

    struct Figure: Identifiable {
        var value: String
        var label: String
        var tone: Tone = .neutral
        var id: String { label }
    }

    var figures: [Figure] {
        let cpu = model.series("CPUUtilization")
        let conn = model.series("DatabaseConnections")
        let rl = model.series("ReadLatency"), wl = model.series("WriteLatency")
        var out: [Figure] = []
        let status = model.overview.value.map { $0.cluster?.status ?? $0.writer?.status ?? "?" }
        out.append(Figure(value: status ?? "—", label: "Status", tone: status == nil || status == "available" ? .neutral : .warning))
        out.append(Figure(value: RDSUnits.format(cpu?.average, unit: .percent), label: "Avg CPU",
                          tone: (cpu?.average ?? 0) > 80 ? .critical : (cpu?.average ?? 0) > 60 ? .warning : .neutral))
        out.append(Figure(value: conn?.latest.map { RDSUnits.number($0) } ?? "—", label: "Connections"))
        let instance = model.currentInstance
        if let free = RDSHealth.freeStorageFraction(instance, metrics: model.metrics.value ?? []) {
            out.append(Figure(value: InsightsFormat.percent(free), label: "Storage free",
                              tone: free < 0.05 ? .critical : free < RDSHealth.lowStorageFraction ? .warning : .neutral))
        } else if let v = model.series("VolumeBytesUsed")?.latest {
            out.append(Figure(value: RDSUnits.format(v, unit: .bytes), label: "Volume used"))
        }
        if rl != nil || wl != nil {
            out.append(Figure(value: "\(RDSUnits.format(rl?.average, unit: .seconds)) / \(RDSUnits.format(wl?.average, unit: .seconds))",
                              label: "Read / write latency"))
        }
        if let load = model.insights.value?.averageLoad {
            out.append(Figure(value: RDSUnits.number(load), label: "Avg active sessions"))
        }
        return out
    }

    var body: some View {
        let items = figures
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, f in
                    if i > 0 { slash }
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) { value(f); label(f) }
                }
                Spacer(minLength: 0)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: DS.Space.l, alignment: .leading)], alignment: .leading, spacing: DS.Space.m) {
                ForEach(items) { f in
                    VStack(alignment: .leading, spacing: DS.Space.xxs) { value(f); label(f) }
                }
            }
        }
        .padding(.horizontal, DS.Space.xs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Key figures")
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
        Text(f.label).font(DS.Typo.body).foregroundStyle(.secondary).lineLimit(1).fixedSize()
    }

    var slash: some View {
        Text("/")
            .font(.system(size: 20, weight: .light))
            .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
            .padding(.horizontal, DS.Space.l)
    }
}

// MARK: Configuration

struct RDSConfigurationSection: View {
    @ObservedObject var model: RDSDashboardModel

    var body: some View {
        let isCluster = model.settings?.isCluster ?? false
        InsightsCard(title: isCluster ? "Cluster" : "Instance", systemImage: "server.rack", isLoading: model.overview.isLoading) {
            SectionBody(state: model.overview) { o in
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    if let c = o.cluster {
                        clusterHeader(c)
                        members(c, o)
                        Divider()
                    }
                    if let i = o.instance(model.selectedMember) {
                        instanceHeader(i, showName: o.cluster != nil)
                        facts(i, cluster: o.cluster)
                    }
                    pending(o)
                }
            }
        }
    }

    func clusterHeader(_ c: RDSClusterInfo) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Text(c.identifier).font(DS.Typo.headline).lineLimit(1).fixedSize()
                statusTag(c.status)
                Tag(engineLabel(c.engine, c.engineVersion), tone: .neutral, uppercase: false)
                if c.isServerlessV2 {
                    Tag("Serverless v2 \(RDSUnits.number(c.serverlessMinACU ?? 0))–\(RDSUnits.number(c.serverlessMaxACU ?? 0)) ACU", tone: .info, uppercase: false)
                }
                Tag(c.storageEncrypted ? "Encrypted" : "Not encrypted", tone: c.storageEncrypted ? .good : .warning)
                if c.deletionProtection { Tag("Deletion protection", tone: .good) }
                Spacer(minLength: 0)
            }
            LazyVGrid(columns: Self.factColumns, alignment: .leading, spacing: DS.Space.m) {
                Fact("Writer endpoint", c.endpoint ?? "—", mono: true)
                Fact("Reader endpoint", c.readerEndpoint ?? "—", mono: true)
                Fact("Storage", c.storageType == "aurora-iopt1" ? "Aurora I/O-Optimized" : "Aurora Standard")
                Fact("Backups", backups(c.backupRetentionDays, c.backupWindow))
                Fact("Maintenance window", c.maintenanceWindow ?? "—", mono: true)
                Fact("Cluster parameter group", c.parameterGroup ?? "—")
                Fact("Availability zones", c.availabilityZones.joined(separator: ", ").nilIfEmpty ?? "—")
                Fact("Cluster resource ID", c.resourceID ?? "—", mono: true)
            }
        }
    }

    func members(_ c: RDSClusterInfo, _ o: RDSOverview) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            Text("Members").font(DS.Typo.caption.weight(.medium)).foregroundStyle(.secondary)
            ForEach(Array(c.members.enumerated()), id: \.element.id) { n, m in
                let i = o.instances.first { $0.identifier == m.identifier }
                let selected = (model.selectedMember ?? c.writer) == m.identifier
                FindingRow(index: n, highlight: selected ? .info : nil) {
                    HStack(spacing: DS.Space.s) {
                        Text(m.identifier).font(DS.Typo.callout.weight(.medium))
                        Tag(m.isWriter ? "writer" : "reader", tone: m.isWriter ? .info : .neutral)
                        Text(i?.instanceClass ?? "—").font(DS.Typo.monoSmall).foregroundStyle(.secondary)
                        if let az = i?.availabilityZone { Text(az).font(DS.Typo.caption).foregroundStyle(.secondary) }
                        Spacer(minLength: 0)
                        if let s = i?.status { statusTag(s) }
                        if !selected {
                            Button("Show") { model.selectedMember = m.isWriter ? nil : m.identifier }.controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    func instanceHeader(_ i: RDSInstanceInfo, showName: Bool) -> some View {
        HStack(spacing: DS.Space.s) {
            if showName || model.settings?.isCluster == false { Text(i.identifier).font(DS.Typo.headline).lineLimit(1).fixedSize() }
            statusTag(i.status)
            if !i.isAurora { Tag(engineLabel(i.engine, i.engineVersion), tone: .neutral, uppercase: false) }
            Tag(i.instanceClass, tone: .neutral, uppercase: false)
            if !i.isAurora { Tag(i.multiAZ ? "Multi-AZ" : "Single-AZ", tone: i.multiAZ ? .good : .neutral) }
            if !i.isAurora { Tag(i.storageEncrypted ? "Encrypted" : "Not encrypted", tone: i.storageEncrypted ? .good : .warning) }
            if i.publiclyAccessible { Tag("Publicly accessible", tone: .warning) }
            if !i.isAurora && i.deletionProtection { Tag("Deletion protection", tone: .good) }
            if i.isBurstable { Tag("Burstable", tone: .info) }
            Spacer(minLength: 0)
        }
    }

    static let factColumns = [GridItem(.adaptive(minimum: 230), spacing: DS.Space.l, alignment: .topLeading)]

    @ViewBuilder
    func facts(_ i: RDSInstanceInfo, cluster: RDSClusterInfo?) -> some View {
        LazyVGrid(columns: Self.factColumns, alignment: .leading, spacing: DS.Space.m) {
            Fact("Engine", engineLabel(i.engine, i.engineVersion) + (i.autoMinorVersionUpgrade == true ? " · auto minor upgrades" : ""))
            Fact("Availability", [i.availabilityZone, i.secondaryAvailabilityZone.map { "standby \($0)" }].compactMap { $0 }.joined(separator: " · ").nilIfEmpty ?? "—")
            if !i.isAurora {
                Fact("Storage", storage(i))
                Fact("IOPS / throughput", [i.iops.map { "\(Fmt.count(Int64($0))) IOPS" }, i.storageThroughputMiBps.map { "\($0) MiB/s" }]
                    .compactMap { $0 }.joined(separator: " · ").nilIfEmpty ?? "baseline")
                Fact("Backups", backups(i.backupRetentionDays, i.backupWindow))
            }
            Fact("Maintenance window", i.maintenanceWindow ?? "—", mono: true)
            Fact("CA certificate", certificate(i), tone: certificateTone(i))
            Fact("Parameter group", i.parameterGroups.map { "\($0.name) (\($0.status ?? "?"))" }.joined(separator: ", ").nilIfEmpty ?? "—",
                 tone: i.parameterGroups.contains { $0.status == "pending-reboot" } ? .warning : .neutral)
            Fact("Performance Insights", i.performanceInsightsEnabled ? "On · \(retention(i.performanceInsightsRetentionDays))" : "Off",
                 tone: i.performanceInsightsEnabled ? .neutral : .warning)
            Fact("Enhanced Monitoring", (i.monitoringInterval ?? 0) > 0 ? "Every \(i.monitoringInterval ?? 0) s" : "Off")
            Fact("Endpoint", i.endpoint.map { "\($0):\(i.port.map(String.init) ?? "")" } ?? "—", mono: true)
            Fact("Resource ID", i.resourceID ?? "—", mono: true)
            if !i.pendingModifiedValues.isEmpty {
                Fact("Pending modifications", i.pendingModifiedValues.sorted { $0.key < $1.key }.map { "\($0.key) → \($0.value)" }.joined(separator: ", "),
                     tone: .warning)
            }
        }
    }

    @ViewBuilder
    func pending(_ o: RDSOverview) -> some View {
        if let e = o.pendingError {
            Text("Pending maintenance: \(e)").font(DS.Typo.caption).foregroundStyle(.secondary)
        } else if o.pending.isEmpty {
            EmptyFinding(text: "No pending maintenance.")
        }
    }

    func storage(_ i: RDSInstanceInfo) -> String {
        var s = "\(i.storageType ?? "?") · \(RDSUnits.gib(i.allocatedStorageGiB))"
        if let m = i.maxAllocatedStorageGiB { s += " · autoscaling to \(RDSUnits.gib(m))" }
        return s
    }

    func backups(_ days: Int?, _ window: String?) -> String {
        guard let days, days > 0 else { return "Off" }
        return "\(days) day\(days == 1 ? "" : "s")" + (window.map { " · \($0) UTC" } ?? "")
    }

    func retention(_ days: Int?) -> String {
        guard let days else { return "7 days" }
        return days % 31 == 0 && days >= 31 ? "\(days / 31) months" : "\(days) days"
    }

    func certificate(_ i: RDSInstanceInfo) -> String {
        var s = i.caCertificate ?? "—"
        if let till = i.caCertificateValidTill { s += " · until \(RDSHealth.day(till))" }
        return s
    }

    func certificateTone(_ i: RDSInstanceInfo) -> Tone {
        guard let till = i.caCertificateValidTill else { return .neutral }
        let days = till.timeIntervalSinceNow / 86_400
        return days < 0 ? .critical : days < RDSHealth.certificateWarningDays ? .warning : .neutral
    }

    func engineLabel(_ engine: String, _ version: String?) -> String {
        let name: String
        switch engine {
        case "postgres": name = "PostgreSQL"
        case "aurora-postgresql": name = "Aurora PostgreSQL"
        case "aurora-mysql": name = "Aurora MySQL"
        case "mysql": name = "MySQL"
        case "mariadb": name = "MariaDB"
        default: name = engine
        }
        return version.map { "\(name) \($0)" } ?? name
    }

    func statusTag(_ status: String) -> some View {
        Tag(status, tone: status == "available" ? .good : ["stopped", "failed", "storage-full"].contains(status) ? .critical : .warning)
    }
}

/// Label above value, for the facts grid.
struct Fact: View {
    var label: String
    var value: String
    var mono = false
    var tone: Tone = .neutral

    init(_ label: String, _ value: String, mono: Bool = false, tone: Tone = .neutral) {
        self.label = label
        self.value = value
        self.mono = mono
        self.tone = tone
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(DS.Typo.eyebrow).tracking(0.5).foregroundStyle(.secondary)
            Text(value)
                .font(mono ? DS.Typo.monoSmall : DS.Typo.callout)
                .foregroundStyle(tone == .neutral ? Color.primary : Color(nsColor: tone.nsColor.readableText()))
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Metrics

struct RDSMetricsSection: View {
    @ObservedObject var model: RDSDashboardModel

    static let columns = [GridItem(.adaptive(minimum: 300), spacing: DS.Space.m, alignment: .top)]

    var body: some View {
        let target = model.metricTarget
        InsightsCard(title: "CloudWatch metrics", systemImage: "chart.xyaxis.line", isLoading: model.metrics.isLoading, plain: true) {
            Text("\(target.instanceID ?? target.clusterID ?? "") · \(model.range.period >= 60 ? "\(model.range.period / 60) min" : "\(model.range.period) s") points")
                .font(DS.Typo.caption).foregroundStyle(.tertiary)
        } content: {
            SectionBody(state: model.metrics) { series in
                if series.isEmpty {
                    EmptyFinding(text: "CloudWatch returned no metrics for \(target.instanceID ?? target.clusterID ?? "this resource").", systemImage: "tray", tone: .neutral)
                } else {
                    LazyVGrid(columns: Self.columns, alignment: .leading, spacing: DS.Space.m) {
                        ForEach(series) { s in
                            RDSMetricChart(title: s.title, unit: s.unit, points: s.points, range: model.range,
                                           tint: tint(s), ceiling: s.unit == .percent ? 100 : nil)
                        }
                    }
                }
            }
        }
    }

    func tint(_ s: RDSMetricSeries) -> Color {
        switch s.metricName {
        case "CPUUtilization", "ACUUtilization", "ServerlessDatabaseCapacity", "CPUCreditBalance": return .blue
        case "DatabaseConnections": return .purple
        case "FreeableMemory", "FreeStorageSpace", "FreeLocalStorage", "VolumeBytesUsed": return .teal
        case "ReadLatency", "WriteLatency", "DiskQueueDepth", "AuroraReplicaLag", "AuroraReplicaLagMaximum": return .orange
        default: return .indigo
        }
    }
}

// MARK: Performance Insights

struct RDSInsightsSection: View {
    @ObservedObject var model: RDSDashboardModel

    var body: some View {
        InsightsCard(title: "Performance Insights", systemImage: "gauge.with.dots.needle.67percent",
                     subtitle: "Database load in average active sessions (AAS) over the range, by statement and by wait event.",
                     isLoading: model.insights.isLoading) {
            SectionBody(state: model.insights) { pi in
                if !pi.enabled {
                    disabled(pi.instanceID)
                } else {
                    content(pi)
                }
            }
        }
    }

    func disabled(_ id: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Banner(.info, "Performance Insights is off for \(id), so top SQL and wait events are not available.")
            Text("Enable it in the RDS console (Modify → Monitoring → Performance Insights; 7 days of history are free), or with the CLI:")
                .font(DS.Typo.caption).foregroundStyle(.secondary)
            Text("aws rds modify-db-instance --db-instance-identifier \(id) --enable-performance-insights --apply-immediately")
                .font(DS.Typo.monoSmall).textSelection(.enabled)
                .padding(DS.Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).fill(Color.primary.opacity(0.05)))
            Text("TableExtra never changes your AWS resources: run it yourself if you want it.").font(DS.Typo.caption).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    func content(_ pi: RDSPerformanceInsights) -> some View {
        if !pi.load.isEmpty {
            RDSMetricChart(title: "DB load (AAS)", unit: .count, points: pi.load, range: model.range, tint: .green)
        }
        Text("Top SQL").font(DS.Typo.caption.weight(.medium)).foregroundStyle(.secondary).padding(.top, DS.Space.xs)
        if pi.topSQL.isEmpty {
            EmptyFinding(text: "No SQL activity recorded in this range.", systemImage: "tray", tone: .neutral)
        } else {
            let top = pi.topSQL.map(\.load).max() ?? 0
            VStack(spacing: DS.Space.xxs) {
                ForEach(Array(pi.topSQL.enumerated()), id: \.element.id) { n, q in
                    FindingRow(index: n, highlight: nil) {
                        HStack(spacing: DS.Space.m) {
                            HeatBarCell(text: RDSUnits.number(q.load), fraction: top > 0 ? q.load / top : 0,
                                        tone: q.load >= 1 ? .warning : .neutral)
                                .frame(width: 90)
                                .help("\(RDSUnits.number(q.load)) average active sessions")
                            HighlightedSQLLine(sql: q.statement)
                            Spacer(minLength: 0)
                            Button {
                                Pasteboard.copy(q.statement)
                            } label: {
                                Image(systemName: "doc.on.doc").font(.system(size: 10.5))
                            }
                            .buttonStyle(.borderless)
                            .help("Copy SQL")
                        }
                    }
                }
            }
        }
        if !pi.waits.isEmpty {
            Text("Top wait events").font(DS.Typo.caption.weight(.medium)).foregroundStyle(.secondary).padding(.top, DS.Space.xs)
            let top = pi.waits.map(\.load).max() ?? 0
            VStack(spacing: 5) {
                ForEach(pi.waits) { w in
                    HStack(spacing: DS.Space.m) {
                        Text(w.name).font(DS.Typo.callout).lineLimit(1).frame(width: 210, alignment: .leading)
                        if let t = w.type { Tag(t, tone: w.name == "CPU" ? .info : .neutral, uppercase: false).frame(width: 80, alignment: .leading) }
                        Meter(fraction: top > 0 ? w.load / top : 0, tone: w.name == "CPU" ? .info : .neutral).frame(height: 5)
                        Text(RDSUnits.number(w.load)).font(DS.Typo.caption).monospacedDigit().frame(width: 50, alignment: .trailing)
                    }
                    .padding(.horizontal, DS.Space.m + 2)
                }
            }
        }
        ForEach(pi.errors, id: \.self) { Text($0).font(DS.Typo.caption).foregroundStyle(.secondary) }
    }
}

// MARK: Events

struct RDSEventsSection: View {
    @ObservedObject var model: RDSDashboardModel

    var body: some View {
        let items = model.events.value ?? []
        InsightsCard(title: "Events", systemImage: "list.bullet.rectangle",
                     subtitle: "RDS events of the last \(model.range == .week ? "7 days" : "24 hours") (failovers, reboots, backups, configuration changes).",
                     badge: model.events.value.map { "\($0.count)" }, isLoading: model.events.isLoading) {
            SectionBody(state: model.events) { _ in
                if items.isEmpty {
                    EmptyFinding(text: "No events.", systemImage: "tray", tone: .neutral)
                } else {
                    VStack(spacing: DS.Space.xxs) {
                        ForEach(Array(items.prefix(50).enumerated()), id: \.element.id) { n, e in
                            FindingRow(index: n, highlight: important(e) ? .warning : nil) { row(e) }
                        }
                    }
                }
            }
        }
    }

    func important(_ e: RDSEvent) -> Bool {
        !Set(e.categories).isDisjoint(with: ["failover", "failure", "low storage", "recovery", "availability"])
    }

    func row(_ e: RDSEvent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.m) {
            Text(e.date.map { $0.formatted(.dateTime.month(.abbreviated).day().hour().minute()) } ?? "—")
                .font(DS.Typo.caption).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            if let s = e.sourceIdentifier { Text(s).font(DS.Typo.caption.weight(.medium)).lineLimit(1) }
            Text(e.message).font(DS.Typo.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 0)
            ForEach(e.categories.prefix(2), id: \.self) { Tag($0, tone: important(e) ? .warning : .neutral) }
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
