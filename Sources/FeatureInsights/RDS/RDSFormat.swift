import Foundation

/// Unit conversions for CloudWatch values: latencies in seconds shown in ms, bytes in MB/GB, rates per second.
public enum RDSUnits {
    /// Scale chosen for a chart from its largest raw value: plotted value = raw * factor, labelled with `suffix`.
    public struct Scale: Equatable, Sendable {
        public var factor: Double
        public var suffix: String
    }

    public static func scale(for unit: RDSMetricUnit, maxRaw: Double) -> Scale {
        let m = abs(maxRaw.isFinite ? maxRaw : 0)
        switch unit {
        case .percent: return Scale(factor: 1, suffix: "%")
        case .seconds: return m * 1000 >= 1000 ? Scale(factor: 1, suffix: "s") : Scale(factor: 1000, suffix: "ms")
        case .milliseconds: return m >= 1000 ? Scale(factor: 0.001, suffix: "s") : Scale(factor: 1, suffix: "ms")
        case .bytes, .bytesPerSecond:
            let rate = unit == .bytesPerSecond ? "/s" : ""
            if m >= 1_073_741_824 { return Scale(factor: 1 / 1_073_741_824, suffix: "GB" + rate) }
            if m >= 1_048_576 { return Scale(factor: 1 / 1_048_576, suffix: "MB" + rate) }
            if m >= 1024 { return Scale(factor: 1 / 1024, suffix: "KB" + rate) }
            return Scale(factor: 1, suffix: "B" + rate)
        case .count: return Scale(factor: 1, suffix: "")
        case .countPerSecond: return Scale(factor: 1, suffix: "/s")
        case .acu: return Scale(factor: 1, suffix: "ACU")
        }
    }

    /// One value with its own best unit ("42.5%", "3.2 GB", "1.84 ms", "1,204", "350/s").
    public static func format(_ raw: Double?, unit: RDSMetricUnit) -> String {
        guard let raw, raw.isFinite else { return "—" }
        let s = scale(for: unit, maxRaw: raw)
        return axisLabel(raw * s.factor, suffix: s.suffix)
    }

    /// Axis / readout label for an already scaled value.
    public static func axisLabel(_ v: Double, suffix: String) -> String {
        let number = number(v)
        switch suffix {
        case "": return number
        case "%", "/s": return number + suffix
        default: return number + " " + suffix
        }
    }

    /// Up to 3 significant digits, grouping for large numbers.
    public static func number(_ v: Double) -> String {
        let a = abs(v)
        if a == 0 { return "0" }
        if a >= 1000 {
            let f = NumberFormatter()
            f.numberStyle = .decimal
            f.maximumFractionDigits = 0
            return f.string(from: NSNumber(value: v.rounded())) ?? String(Int(v))
        }
        if a >= 100 { return String(format: "%.0f", v) }
        if a >= 10 { return trim(String(format: "%.1f", v)) }
        if a >= 1 { return trim(String(format: "%.2f", v)) }
        if a >= 0.01 { return trim(String(format: "%.2f", v)) }
        return trim(String(format: "%.3f", v))
    }

    private static func trim(_ s: String) -> String {
        guard s.contains(".") else { return s }
        var t = s
        while t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return t
    }

    static func gib(_ n: Int?) -> String {
        guard let n else { return "—" }
        return n >= 1024 && n % 1024 == 0 ? "\(n / 1024) TiB" : "\(n) GiB"
    }
}

/// Warnings shown as banners above the facts card.
public struct RDSWarning: Hashable, Sendable, Identifiable {
    public enum Severity: Int, Sendable { case info, warning, critical }
    public var severity: Severity
    public var text: String
    public var id: String { text }
}

public enum RDSHealth {
    static let certificateWarningDays = 60.0
    static let lowStorageFraction = 0.15

    /// CPU credit ceiling per burstable class (credits earned per hour × 24).
    static let maxCPUCredits: [String: Double] = [
        "db.t2.micro": 144, "db.t2.small": 288, "db.t2.medium": 576, "db.t2.large": 864, "db.t2.xlarge": 1296, "db.t2.2xlarge": 1958,
        "db.t3.micro": 288, "db.t3.small": 576, "db.t3.medium": 576, "db.t3.large": 864, "db.t3.xlarge": 2304, "db.t3.2xlarge": 4608,
        "db.t4g.micro": 288, "db.t4g.small": 576, "db.t4g.medium": 576, "db.t4g.large": 864, "db.t4g.xlarge": 2304, "db.t4g.2xlarge": 4608,
    ]

    /// Free storage / allocated storage (non-Aurora; Aurora storage grows by itself).
    public static func freeStorageFraction(_ instance: RDSInstanceInfo?, metrics: [RDSMetricSeries]) -> Double? {
        guard let instance, !instance.isAurora, let total = instance.allocatedStorageBytes, total > 0,
              let free = metrics.first(where: { $0.metricName == "FreeStorageSpace" })?.latest else { return nil }
        return min(1, max(0, free / total))
    }

    public static func warnings(overview: RDSOverview?, instanceID: String?, metrics: [RDSMetricSeries], now: Date = Date()) -> [RDSWarning] {
        guard let overview else { return [] }
        var out: [RDSWarning] = []
        let instance = overview.instance(instanceID)
        let status = overview.cluster?.status ?? instance?.status
        if let status, status != "available" {
            out.append(RDSWarning(severity: ["stopped", "failed", "storage-full", "incompatible-parameters", "inaccessible-encryption-credentials"].contains(status) ? .critical : .warning,
                                  text: "Status is \(status)."))
        }
        for p in overview.pending {
            var text = "Pending maintenance on \(p.resource): \(p.action)"
            if let d = p.description { text += " — \(d)" }
            if let d = p.currentApplyDate ?? p.autoAppliedAfter { text += ". Applied in the maintenance window after \(day(d))" }
            if let d = p.forcedApplyDate { text += ", forced on \(day(d))" }
            out.append(RDSWarning(severity: .warning, text: text + "."))
        }
        // Certificates: every instance (Aurora members can differ).
        for i in overview.instances {
            guard let till = i.caCertificateValidTill else { continue }
            let days = till.timeIntervalSince(now) / 86_400
            let who = overview.instances.count > 1 ? " of \(i.identifier)" : ""
            if days < 0 {
                out.append(RDSWarning(severity: .critical, text: "The CA certificate\(who) (\(i.caCertificate ?? "?")) expired on \(day(till)). Clients verifying the server certificate will fail: rotate it (Modify → Certificate authority)."))
            } else if days < certificateWarningDays {
                out.append(RDSWarning(severity: .warning, text: "The CA certificate\(who) (\(i.caCertificate ?? "?")) expires in \(Int(days)) days (\(day(till))). Rotate it to rds-ca-rsa2048-g1 or newer, then update client trust stores."))
            }
        }
        if let free = freeStorageFraction(instance, metrics: metrics), free < lowStorageFraction {
            var text = "Only \(String(format: "%.1f", free * 100))% storage free (\(RDSUnits.format(metrics.first { $0.metricName == "FreeStorageSpace" }?.latest, unit: .bytes)) of \(RDSUnits.gib(instance?.allocatedStorageGiB)))."
            if let max = instance?.maxAllocatedStorageGiB {
                text += " Storage autoscaling is on (up to \(RDSUnits.gib(max)))."
            } else {
                text += " Storage autoscaling is off: increase the allocated storage or enable autoscaling."
            }
            out.append(RDSWarning(severity: free < 0.05 ? .critical : .warning, text: text))
        }
        if let instance, instance.isBurstable, let credits = metrics.first(where: { $0.metricName == "CPUCreditBalance" })?.latest {
            let ceiling = maxCPUCredits[instance.instanceClass]
            let low = ceiling.map { credits < $0 * 0.15 } ?? (credits < 30)
            if low {
                out.append(RDSWarning(severity: credits < 5 ? .critical : .warning,
                                      text: "\(instance.instanceClass) is a burstable class with \(Int(credits)) CPU credits left\(ceiling.map { " of \(Int($0))" } ?? ""). When they run out, CPU is throttled to the baseline: consider an m- or r-class instance."))
            }
        }
        var pendingReboot: [String] = []
        for i in overview.instances {
            for g in i.parameterGroups where g.status == "pending-reboot" { pendingReboot.append("\(g.name) on \(i.identifier)") }
        }
        for m in overview.cluster?.members ?? [] where m.parameterGroupStatus == "pending-reboot" {
            pendingReboot.append("\(overview.cluster?.parameterGroup ?? "cluster parameter group") on \(m.identifier)")
        }
        if !pendingReboot.isEmpty {
            out.append(RDSWarning(severity: .warning, text: "Parameter changes wait for a reboot: \(pendingReboot.joined(separator: ", "))."))
        }
        let pendingValues = (instance?.pendingModifiedValues ?? [:]).merging(overview.cluster?.pendingModifiedValues ?? [:]) { a, _ in a }
        if !pendingValues.isEmpty {
            let list = pendingValues.sorted { $0.key < $1.key }.map { "\($0.key) → \($0.value)" }.joined(separator: ", ")
            out.append(RDSWarning(severity: .info, text: "Pending modifications (next maintenance window or reboot): \(list)."))
        }
        return out.sorted { $0.severity.rawValue > $1.severity.rawValue }
    }

    static func day(_ d: Date) -> String {
        d.formatted(.dateTime.year().month(.abbreviated).day())
    }
}
