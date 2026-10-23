import Foundation
import MTPCore

/// Something that runs an allowed `aws` command and returns its JSON (the real CLI, or a stub in tests).
public protocol AWSCommandRunning: Sendable {
    func json(_ service: String, _ operation: String, _ arguments: [String], settings: AWSSettings?) async throws -> Data
}

extension AWSCLI: AWSCommandRunning {}

/// One `aws` invocation: service, operation, operation arguments (profile / region / output are added by the runner).
public struct AWSCommand: Hashable, Sendable {
    public var service: String
    public var operation: String
    public var arguments: [String]

    /// The command as the user would type it (for the report and the IAM hint).
    public func commandLine(settings: AWSSettings?) -> String {
        let args = (try? AWSCLI.arguments(service: service, operation: operation, arguments: arguments, settings: settings))
            ?? [service, operation] + arguments
        return "aws " + args.map { $0.contains(where: { " \"{}[],".contains($0) }) ? "'\($0)'" : $0 }.joined(separator: " ")
    }
}

/// The read-only commands the dashboard runs. Pure: tests check them without launching anything.
public enum RDSCommands {
    public static func describeInstance(_ id: String) -> AWSCommand {
        AWSCommand(service: "rds", operation: "describe-db-instances", arguments: ["--db-instance-identifier", id])
    }

    public static func describeClusterInstances(_ clusterID: String) -> AWSCommand {
        AWSCommand(service: "rds", operation: "describe-db-instances", arguments: ["--filters", "Name=db-cluster-id,Values=\(clusterID)"])
    }

    public static func describeCluster(_ id: String) -> AWSCommand {
        AWSCommand(service: "rds", operation: "describe-db-clusters", arguments: ["--db-cluster-identifier", id])
    }

    /// By ARN when known: a `--filters` call needs the permission on every database (`*`), while
    /// `--resource-identifier` works with a policy scoped to this one instance or cluster.
    public static func pendingMaintenance(_ id: String, isCluster: Bool, arn: String? = nil) -> AWSCommand {
        if let arn, !arn.isEmpty {
            return AWSCommand(service: "rds", operation: "describe-pending-maintenance-actions", arguments: ["--resource-identifier", arn])
        }
        return AWSCommand(service: "rds", operation: "describe-pending-maintenance-actions",
                          arguments: ["--filters", "Name=\(isCluster ? "db-cluster-id" : "db-instance-id"),Values=\(id)"])
    }

    public static func events(_ id: String, isCluster: Bool, minutes: Int) -> AWSCommand {
        AWSCommand(service: "rds", operation: "describe-events",
                   arguments: ["--source-type", isCluster ? "db-cluster" : "db-instance", "--source-identifier", id, "--duration", "\(minutes)"])
    }

    public static func metricData(_ definitions: [RDSMetricDefinition], target: RDSMetricTarget, range: RDSTimeRange, now: Date) -> AWSCommand {
        let queries: [[String: Any]] = definitions.compactMap { d in
            let value = d.dimension == .cluster ? target.clusterID : target.instanceID
            guard let value else { return nil }
            return [
                "Id": d.id,
                "Label": d.metricName,
                "ReturnData": true,
                "MetricStat": [
                    "Metric": ["Namespace": "AWS/RDS", "MetricName": d.metricName,
                               "Dimensions": [["Name": d.dimension.rawValue, "Value": value]]],
                    "Period": range.period,
                    "Stat": d.stat,
                ] as [String: Any],
            ]
        }
        let json = (try? JSONSerialization.data(withJSONObject: queries, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        let (start, end) = window(range, now: now)
        return AWSCommand(service: "cloudwatch", operation: "get-metric-data",
                          arguments: ["--metric-data-queries", json, "--start-time", iso(start), "--end-time", iso(end),
                                      "--scan-by", "TimestampAscending"])
    }

    /// `group` is db.sql_tokenized or db.wait_event.
    public static func dimensionKeys(resourceID: String, group: String, range: RDSTimeRange, now: Date, limit: Int = 10) -> AWSCommand {
        let (start, end) = window(range, now: now)
        return AWSCommand(service: "pi", operation: "describe-dimension-keys",
                          arguments: ["--service-type", "RDS", "--identifier", resourceID, "--start-time", iso(start), "--end-time", iso(end),
                                      "--metric", "db.load.avg", "--group-by", "{\"Group\":\"\(group)\",\"Limit\":\(limit)}"])
    }

    public static func loadMetric(resourceID: String, range: RDSTimeRange, now: Date) -> AWSCommand {
        let (start, end) = window(range, now: now)
        return AWSCommand(service: "pi", operation: "get-resource-metrics",
                          arguments: ["--service-type", "RDS", "--identifier", resourceID, "--start-time", iso(start), "--end-time", iso(end),
                                      "--period-in-seconds", "\(range.period)", "--metric-queries", "[{\"Metric\":\"db.load.avg\"}]"])
    }

    /// Range ending at `now`, aligned down to the period so successive refreshes ask for the same buckets.
    static func window(_ range: RDSTimeRange, now: Date) -> (Date, Date) {
        let p = Double(range.period)
        let end = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / p).rounded(.down) * p)
        return (end.addingTimeInterval(-range.seconds), end)
    }

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }
}

/// CloudWatch metrics charted for an instance / Aurora member.
public enum RDSMetricCatalog {
    public static func definitions(for t: RDSMetricTarget) -> [RDSMetricDefinition] {
        typealias D = RDSMetricDefinition
        var out: [D] = []
        let hasInstance = t.instanceID != nil
        // Without an instance (cluster description failed), Aurora still publishes these per cluster.
        let dim: D.Dimension = hasInstance ? .instance : .cluster
        out.append(D(id: "cpu", metricName: "CPUUtilization", title: "CPU", unit: .percent, dimension: dim))
        out.append(D(id: "connections", metricName: "DatabaseConnections", title: "Connections", unit: .count, dimension: dim))
        out.append(D(id: "memory", metricName: "FreeableMemory", title: "Freeable memory", unit: .bytes, dimension: dim))
        if t.isAurora {
            if hasInstance {
                out.append(D(id: "localstorage", metricName: "FreeLocalStorage", title: "Free local storage", unit: .bytes, dimension: .instance))
            }
            if t.clusterID != nil {
                out.append(D(id: "volume", metricName: "VolumeBytesUsed", title: "Cluster volume used", unit: .bytes, dimension: .cluster))
            }
        } else {
            out.append(D(id: "storage", metricName: "FreeStorageSpace", title: "Free storage", unit: .bytes, dimension: dim))
        }
        out.append(D(id: "readiops", metricName: "ReadIOPS", title: "Read IOPS", unit: .countPerSecond, dimension: dim))
        out.append(D(id: "writeiops", metricName: "WriteIOPS", title: "Write IOPS", unit: .countPerSecond, dimension: dim))
        out.append(D(id: "readlatency", metricName: "ReadLatency", title: "Read latency", unit: .seconds, dimension: dim))
        out.append(D(id: "writelatency", metricName: "WriteLatency", title: "Write latency", unit: .seconds, dimension: dim))
        out.append(D(id: "queue", metricName: "DiskQueueDepth", title: "Disk queue depth", unit: .count, dimension: dim))
        out.append(D(id: "netin", metricName: "NetworkReceiveThroughput", title: "Network in", unit: .bytesPerSecond, dimension: dim))
        out.append(D(id: "netout", metricName: "NetworkTransmitThroughput", title: "Network out", unit: .bytesPerSecond, dimension: dim))
        if t.isAurora && hasInstance {
            // Readers report their own lag; the writer reports the worst reader.
            out.append(t.isWriter
                       ? D(id: "replicalag", metricName: "AuroraReplicaLagMaximum", title: "Max replica lag", unit: .milliseconds, dimension: .instance)
                       : D(id: "replicalag", metricName: "AuroraReplicaLag", title: "Replica lag", unit: .milliseconds, dimension: .instance))
        }
        if t.isServerless && hasInstance {
            out.append(D(id: "acu", metricName: "ServerlessDatabaseCapacity", title: "Capacity (ACU)", unit: .acu, dimension: .instance))
            out.append(D(id: "acuutil", metricName: "ACUUtilization", title: "ACU utilization", unit: .percent, dimension: .instance))
        }
        if t.isBurstable && hasInstance {
            out.append(D(id: "cpucredits", metricName: "CPUCreditBalance", title: "CPU credit balance", unit: .count, dimension: .instance))
        }
        return out
    }
}

/// Loads RDS description, CloudWatch metrics, Performance Insights and events for one `AWSSettings`.
public struct RDSService: Sendable {
    public let settings: AWSSettings
    public let runner: AWSCommandRunning

    public init(settings: AWSSettings, runner: AWSCommandRunning = AWSCLI.resolved()) {
        self.settings = settings
        self.runner = runner
    }

    var identifier: String { settings.identifier ?? "" }

    func run(_ c: AWSCommand) async throws -> Data {
        try await runner.json(c.service, c.operation, c.arguments, settings: settings)
    }

    /// Instance or cluster description, members, pending maintenance (whose failure only fills `pendingError`).
    public func overview() async throws -> RDSOverview {
        var result: RDSOverview
        if settings.isCluster {
            guard let cluster = try RDSParser.clusters(try await run(RDSCommands.describeCluster(identifier))).first else {
                throw AWSCLIError.notFound("DB cluster \(identifier)")
            }
            let instances = try RDSParser.instances(try await run(RDSCommands.describeClusterInstances(identifier)))
            let order = cluster.members.map(\.identifier)
            result = RDSOverview(cluster: cluster,
                                 instances: instances.sorted { (order.firstIndex(of: $0.identifier) ?? .max) < (order.firstIndex(of: $1.identifier) ?? .max) })
        } else {
            let instances = try RDSParser.instances(try await run(RDSCommands.describeInstance(identifier)))
            guard !instances.isEmpty else { throw AWSCLIError.notFound("DB instance \(identifier)") }
            result = RDSOverview(instances: instances)
        }
        do {
            let ownARN = settings.isCluster ? result.cluster?.arn : result.instances.first?.arn
            var pending = try RDSParser.pendingActions(try await run(RDSCommands.pendingMaintenance(identifier, isCluster: settings.isCluster, arn: ownARN)))
            if settings.isCluster {
                // Instance-level actions (OS updates) are filed per member.
                for i in result.instances {
                    pending += (try? RDSParser.pendingActions(try await run(RDSCommands.pendingMaintenance(i.identifier, isCluster: false, arn: i.arn)))) ?? []
                }
            }
            result.pending = pending
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            result.pendingError = error.localizedDescription
        }
        return result
    }

    public func metrics(target: RDSMetricTarget, range: RDSTimeRange, now: Date = Date()) async throws -> [RDSMetricSeries] {
        let defs = RDSMetricCatalog.definitions(for: target)
        let data = try await run(RDSCommands.metricData(defs, target: target, range: range, now: now))
        return try RDSParser.metricData(data, definitions: defs)
    }

    /// Top SQL, waits and the load curve. Not called when Performance Insights is off (the caller knows from the description).
    public func performanceInsights(instance: RDSInstanceInfo, range: RDSTimeRange, now: Date = Date()) async throws -> RDSPerformanceInsights {
        guard instance.performanceInsightsEnabled, let rid = instance.resourceID else {
            return RDSPerformanceInsights(enabled: false, instanceID: instance.identifier)
        }
        // Top SQL is the main result: its failure fails the section. Waits and the load curve degrade to a note.
        async let sqlData = run(RDSCommands.dimensionKeys(resourceID: rid, group: "db.sql_tokenized", range: range, now: now))
        async let waitData = run(RDSCommands.dimensionKeys(resourceID: rid, group: "db.wait_event", range: range, now: now))
        async let loadData = run(RDSCommands.loadMetric(resourceID: rid, range: range, now: now))
        var result = RDSPerformanceInsights(enabled: true, instanceID: instance.identifier)
        do {
            result.topSQL = try RDSParser.topSQL(try await sqlData)
        } catch {
            _ = try? await waitData
            _ = try? await loadData
            throw error
        }
        do { result.waits = try RDSParser.waits(try await waitData) } catch { result.errors.append("Wait events: \(error.localizedDescription)") }
        do { result.load = try RDSParser.resourceMetric(try await loadData) } catch { result.errors.append("DB load: \(error.localizedDescription)") }
        return result
    }

    /// Events of the instance / cluster (and, for a cluster, of `memberID`), newest first.
    public func events(range: RDSTimeRange, memberID: String? = nil) async throws -> [RDSEvent] {
        var events = try RDSParser.events(try await run(RDSCommands.events(identifier, isCluster: settings.isCluster, minutes: range.eventMinutes)))
        if settings.isCluster, let memberID {
            events += (try? RDSParser.events(try await run(RDSCommands.events(memberID, isCluster: false, minutes: range.eventMinutes)))) ?? []
            events.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        }
        return events
    }
}

/// Commands, IAM actions and the minimal policy, for settings screens and docs.
public enum RDSPermissions {
    public static let iamActions = ["rds:DescribeDBInstances", "rds:DescribeDBClusters", "rds:DescribeEvents",
                                    "rds:DescribePendingMaintenanceActions", "cloudwatch:GetMetricData",
                                    "pi:DescribeDimensionKeys", "pi:GetResourceMetrics"]

    public static let policyJSON = """
        {
          "Version": "2012-10-17",
          "Statement": [{
            "Effect": "Allow",
            "Action": [
              "rds:DescribeDBInstances", "rds:DescribeDBClusters", "rds:DescribeEvents",
              "rds:DescribePendingMaintenanceActions", "cloudwatch:GetMetricData",
              "pi:DescribeDimensionKeys", "pi:GetResourceMetrics"
            ],
            "Resource": "*"
          }]
        }
        """
}
