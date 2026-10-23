import Foundation
import MTPCore
import MTPUIKit
import SwiftUI

/// State of the RDS screen. Sections load and fail independently.
@MainActor
public final class RDSDashboardModel: ObservableObject {
    public let context: WorkspaceContext
    /// nil when the connection has no complete AWS settings (the view shows how to set them).
    public let settings: AWSSettings?
    let service: RDSService?

    @Published var overview = SectionState<RDSOverview>()
    @Published var metrics = SectionState<[RDSMetricSeries]>()
    @Published var insights = SectionState<RDSPerformanceInsights>()
    @Published var events = SectionState<[RDSEvent]>()
    @Published var range: RDSTimeRange = .sixHours {
        didSet { if range != oldValue { reload(full: false) } }
    }
    /// Aurora member whose metrics / Performance Insights are shown (nil = writer).
    @Published var selectedMember: String? {
        didSet { if selectedMember != oldValue { reload(full: false) } }
    }
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var isRefreshing = false

    private var task: Task<Void, Never>?

    public convenience init(context: WorkspaceContext) {
        let s = context.connection.effectiveAWS
        self.init(context: context, settings: s, runner: AWSCLI.resolved())
    }

    /// `runner` is the real CLI in the app, a stub or fake script in tests.
    public init(context: WorkspaceContext, settings: AWSSettings?, runner: AWSCommandRunning) {
        self.context = context
        let usable = settings?.isComplete == true ? settings : nil
        self.settings = usable
        self.service = usable.map { RDSService(settings: $0, runner: runner) }
    }

    func start() {
        if lastRefresh == nil && task == nil { reload(full: true) }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Restarts loading; `full` also reloads the description (otherwise only range-dependent sections).
    func reload(full: Bool) {
        task?.cancel()
        task = Task { [weak self] in await self?.refresh(full: full) }
    }

    /// Description first (the metrics need the writer, class and Performance Insights id), then the rest concurrently.
    public func refresh(full: Bool = true) async {
        guard let service else { return }
        isRefreshing = true
        defer {
            if !Task.isCancelled {
                isRefreshing = false
                lastRefresh = Date()
            }
        }
        let range = self.range
        async let ev: Void = load({ $0.events = $1 }, { $0.events }) { [selectedMember] in
            try await service.events(range: range, memberID: selectedMember)
        }
        if full || overview.value == nil {
            await load({ $0.overview = $1 }, { $0.overview }) { try await service.overview() }
        }
        guard !Task.isCancelled else { _ = await ev; return }
        let target = metricTarget
        let instance = currentInstance
        async let m: Void = load({ $0.metrics = $1 }, { $0.metrics }) { try await service.metrics(target: target, range: range) }
        async let pi: Void = load({ $0.insights = $1 }, { $0.insights }) {
            guard let instance else { throw AWSCLIError.failed("Performance Insights needs the instance description, which did not load.") }
            return try await service.performanceInsights(instance: instance, range: range)
        }
        _ = await (ev, m, pi)
    }

    private func load<T>(_ set: @MainActor (RDSDashboardModel, SectionState<T>) -> Void,
                         _ get: @MainActor (RDSDashboardModel) -> SectionState<T>,
                         _ work: @escaping @Sendable () async throws -> T) async {
        var state = get(self)
        state.isLoading = true
        set(self, state)
        do {
            let value = try await work()
            guard !Task.isCancelled else { return }
            state = get(self)
            state.value = value
            state.error = nil
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? AWSCLIError) == .cancelled {
                state = get(self)
                state.isLoading = false
                set(self, state)
                return
            }
            state = get(self)
            state.error = error.localizedDescription
        }
        state.isLoading = false
        state.updatedAt = Date()
        set(self, state)
    }

    // MARK: Derived

    var currentInstance: RDSInstanceInfo? { overview.value?.instance(selectedMember) }

    var metricTarget: RDSMetricTarget {
        let o = overview.value
        let i = currentInstance
        let isCluster = settings?.isCluster ?? false
        let clusterID = o?.cluster?.identifier ?? (isCluster ? settings?.identifier : i?.clusterIdentifier)
        let writer = o?.cluster?.writer
        return RDSMetricTarget(instanceID: i?.identifier ?? (isCluster ? nil : settings?.identifier),
                               clusterID: clusterID,
                               instanceClass: i?.instanceClass,
                               isAurora: i?.isAurora ?? isCluster,
                               isWriter: writer == nil || writer == i?.identifier,
                               isServerless: i?.isServerless ?? false)
    }

    var warnings: [RDSWarning] {
        RDSHealth.warnings(overview: overview.value, instanceID: selectedMember, metrics: metrics.value ?? [])
    }

    func series(_ metricName: String) -> RDSMetricSeries? { metrics.value?.first { $0.metricName == metricName } }

    var subtitle: String {
        guard let s = settings else { return "not configured" }
        var parts = [s.identifier ?? "?", s.region ?? "?", s.profile.flatMap { $0.isEmpty ? nil : $0 } ?? "default profile"]
        if s.isCluster { parts[0] += " (cluster)" }
        if let last = lastRefresh { parts.append("updated \(last.formatted(date: .omitted, time: .standard))") }
        return parts.joined(separator: " · ")
    }

    // MARK: Claude

    /// Everything loaded, as plain text (sections that failed say why). No row data: AWS metadata and metrics only.
    public func reportForClaude() -> String {
        var out = "AWS RDS report"
        if let s = settings {
            out += " for \(s.isCluster ? "cluster" : "instance") \(s.identifier ?? "?") in \(s.region ?? "?")"
        }
        out += "\nTime range: last \(range.title)"
        if let last = lastRefresh { out += ", loaded \(ISO8601DateFormatter().string(from: last))" }
        out += "\n"

        out += "\n## Configuration\n"
        if let e = overview.error { out += "Not available: \(e)\n" }
        if let o = overview.value {
            if let c = o.cluster {
                out += "Cluster \(c.identifier): \(c.engine) \(c.engineVersion ?? "?") (\(c.engineMode ?? "provisioned")), status \(c.status), "
                out += "storage \(c.storageType ?? "aurora"), encrypted \(c.storageEncrypted), deletion protection \(c.deletionProtection), "
                out += "backups \(c.backupRetentionDays ?? 0) days (window \(c.backupWindow ?? "?")), maintenance \(c.maintenanceWindow ?? "?"), "
                out += "parameter group \(c.parameterGroup ?? "?")"
                if let min = c.serverlessMinACU, let max = c.serverlessMaxACU { out += ", Serverless v2 \(RDSUnits.number(min))–\(RDSUnits.number(max)) ACU" }
                out += "\nMembers: " + c.members.map { m in
                    let cls = o.instances.first { $0.identifier == m.identifier }?.instanceClass ?? "?"
                    return "\(m.identifier) (\(m.isWriter ? "writer" : "reader"), \(cls))"
                }.joined(separator: ", ") + "\n"
            }
            for i in o.instances { out += instanceLine(i) }
            if !o.pending.isEmpty {
                out += "Pending maintenance:\n" + o.pending.map { p in
                    "- \(p.resource): \(p.action) \(p.description ?? "") auto-apply after \(p.autoAppliedAfter.map(RDSHealth.day) ?? "-"), forced \(p.forcedApplyDate.map(RDSHealth.day) ?? "-")"
                }.joined(separator: "\n") + "\n"
            } else if let e = o.pendingError {
                out += "Pending maintenance: not available (\(e))\n"
            } else {
                out += "Pending maintenance: none\n"
            }
        } else if overview.error == nil {
            out += "Not loaded\n"
        }
        let w = warnings
        if !w.isEmpty { out += "\n## Warnings\n" + w.map { "- \($0.text)" }.joined(separator: "\n") + "\n" }

        out += "\n## CloudWatch metrics (\(metricTarget.instanceID ?? metricTarget.clusterID ?? "?"), period \(range.period) s)\n"
        if let e = metrics.error { out += "Not available: \(e)\n" }
        for s in metrics.value ?? [] {
            if s.points.isEmpty { out += "\(s.metricName): no data\n"; continue }
            out += "\(s.metricName): latest \(RDSUnits.format(s.latest, unit: s.unit)), avg \(RDSUnits.format(s.average, unit: s.unit)), "
            out += "min \(RDSUnits.format(s.minimum, unit: s.unit)), max \(RDSUnits.format(s.maximum, unit: s.unit)) (\(s.points.count) points)\n"
        }

        out += "\n## Performance Insights\n"
        if let e = insights.error { out += "Not available: \(e)\n" }
        if let p = insights.value {
            if !p.enabled {
                out += "Not enabled on \(p.instanceID).\n"
            } else {
                if let avg = p.averageLoad {
                    out += "Average DB load: \(RDSUnits.number(avg)) active sessions, peak \(RDSUnits.number(p.load.map(\.value).max() ?? 0))\n"
                }
                out += "Top SQL by db.load.avg (average active sessions):\n"
                for (n, q) in p.topSQL.enumerated() {
                    out += "\(n + 1). [\(RDSUnits.number(q.load))] \(InsightsFormat.oneLine(q.statement, limit: 1500))\n"
                }
                out += "Top wait events:\n"
                for wv in p.waits { out += "- \(wv.type.map { "\($0): " } ?? "")\(wv.name) \(RDSUnits.number(wv.load))\n" }
                for e in p.errors { out += "(\(e))\n" }
            }
        }

        out += "\n## Events (last \(range == .week ? "7 days" : "24 hours"))\n"
        if let e = events.error { out += "Not available: \(e)\n" }
        let evs = events.value ?? []
        if events.value != nil && evs.isEmpty { out += "None\n" }
        for e in evs.prefix(40) {
            out += "- \(e.date.map { ISO8601DateFormatter().string(from: $0) } ?? "?") \(e.sourceIdentifier ?? ""): \(e.message)\n"
        }
        return out
    }

    private func instanceLine(_ i: RDSInstanceInfo) -> String {
        var parts = ["Instance \(i.identifier): \(i.engine) \(i.engineVersion ?? "?"), \(i.instanceClass), status \(i.status)"]
        parts.append(i.multiAZ ? "Multi-AZ" : "Single-AZ \(i.availabilityZone ?? "")")
        if !i.isAurora {
            var storage = "storage \(i.storageType ?? "?") \(RDSUnits.gib(i.allocatedStorageGiB))"
            if let m = i.maxAllocatedStorageGiB { storage += " (autoscaling to \(RDSUnits.gib(m)))" }
            if let iops = i.iops { storage += ", \(iops) IOPS" }
            if let t = i.storageThroughputMiBps { storage += ", \(t) MiB/s" }
            parts.append(storage)
            parts.append("backups \(i.backupRetentionDays ?? 0) days")
        }
        parts.append("public \(i.publiclyAccessible)")
        parts.append("encrypted \(i.storageEncrypted)")
        parts.append("deletion protection \(i.deletionProtection)")
        parts.append("CA \(i.caCertificate ?? "?") valid till \(i.caCertificateValidTill.map(RDSHealth.day) ?? "?")")
        parts.append("parameter groups " + i.parameterGroups.map { "\($0.name) (\($0.status ?? "?"))" }.joined(separator: ", "))
        parts.append("Performance Insights \(i.performanceInsightsEnabled ? "on (\(i.performanceInsightsRetentionDays ?? 7) days)" : "off")")
        parts.append("Enhanced Monitoring \((i.monitoringInterval ?? 0) > 0 ? "\(i.monitoringInterval ?? 0) s" : "off")")
        if !i.pendingModifiedValues.isEmpty {
            parts.append("pending: " + i.pendingModifiedValues.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
        }
        return parts.joined(separator: ", ") + "\n"
    }

    var claudeItems: [AskClaudeItem] {
        let report = { AIAttachments.text(self.reportForClaude(), title: "RDS report", systemImage: "cloud") }
        let disabled = overview.value == nil && metrics.value == nil ? "Wait for the RDS data to load" : nil
        return [
            AskClaudeItem("Analyze This Instance's Health", systemImage: "stethoscope", disabledReason: disabled) {
                AIRequest(title: "RDS health", prompt: """
                    Review this AWS RDS report: configuration, warnings, CloudWatch metrics, Performance Insights and events. \
                    List what needs attention, most urgent first, with the reason and the concrete fix (console setting, CLI command or SQL). \
                    Say clearly when everything looks healthy.
                    """, attachments: [report()])
            },
            AskClaudeItem("Why Is CPU / Latency High?", systemImage: "flame", disabledReason: disabled) {
                AIRequest(title: "RDS CPU / latency", prompt: """
                    Using the CPU, IOPS, latency, queue depth and connection metrics, the top SQL and wait events from Performance Insights, \
                    and recent events, explain what drives CPU and latency on this instance and what to do about it (queries to fix, \
                    indexes, parameters, instance changes).
                    """, attachments: [report()])
            },
            AskClaudeItem("Is This Instance Sized Right?", systemImage: "arrow.up.left.and.arrow.down.right", disabledReason: disabled) {
                AIRequest(title: "RDS sizing", prompt: """
                    Based on CPU, memory, connections, storage, IOPS and (for burstable classes) CPU credits over this range, \
                    is this instance class and storage over- or under-provisioned? Suggest a class / storage change with the trade-offs, \
                    and say which longer range would confirm it.
                    """, attachments: [report()])
            },
            AskClaudeItem("Explain the Top SQL", systemImage: "list.number", disabledReason: insights.value?.topSQL.isEmpty == false ? nil : "No Performance Insights top SQL loaded") {
                AIRequest(title: "RDS top SQL", prompt: """
                    Explain the top SQL statements by database load from Performance Insights and their wait events: why each is costly \
                    and how to make it cheaper (indexes, rewrites). Put suggested SQL in one ```sql block.
                    """, attachments: [report()])
            },
        ]
    }
}
