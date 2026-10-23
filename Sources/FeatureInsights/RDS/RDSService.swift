import AWSCloudWatch
import AWSPI
import AWSRDS
import Foundation
import MTPCore

/// The read-only requests the dashboard sends. Pure: tests check them without calling AWS.
public enum RDSRequests {
    public static func describeInstance(_ id: String) -> DescribeDBInstancesInput {
        DescribeDBInstancesInput(dbInstanceIdentifier: id)
    }

    public static func describeClusterInstances(_ clusterID: String) -> DescribeDBInstancesInput {
        DescribeDBInstancesInput(filters: [RDSClientTypes.Filter(name: "db-cluster-id", values: [clusterID])])
    }

    public static func describeCluster(_ id: String) -> DescribeDBClustersInput {
        DescribeDBClustersInput(dbClusterIdentifier: id)
    }

    /// By ARN when known: a filtered call needs the permission on every database (`*`), while
    /// a resource identifier works with a policy scoped to this one instance or cluster.
    public static func pendingMaintenance(_ id: String, isCluster: Bool, arn: String? = nil) -> DescribePendingMaintenanceActionsInput {
        if let arn, !arn.isEmpty { return DescribePendingMaintenanceActionsInput(resourceIdentifier: arn) }
        return DescribePendingMaintenanceActionsInput(filters: [RDSClientTypes.Filter(name: isCluster ? "db-cluster-id" : "db-instance-id", values: [id])])
    }

    public static func events(_ id: String, isCluster: Bool, minutes: Int) -> DescribeEventsInput {
        DescribeEventsInput(duration: minutes, sourceIdentifier: id, sourceType: isCluster ? .dbCluster : .dbInstance)
    }

    public static func metricData(_ definitions: [RDSMetricDefinition], target: RDSMetricTarget, range: RDSTimeRange, now: Date) -> GetMetricDataInput {
        let queries: [CloudWatchClientTypes.MetricDataQuery] = definitions.compactMap { d in
            let value = d.dimension == .cluster ? target.clusterID : target.instanceID
            guard let value else { return nil }
            let metric = CloudWatchClientTypes.Metric(dimensions: [CloudWatchClientTypes.Dimension(name: d.dimension.rawValue, value: value)],
                                                      metricName: d.metricName, namespace: "AWS/RDS")
            return CloudWatchClientTypes.MetricDataQuery(id: d.id, label: d.metricName,
                                                         metricStat: CloudWatchClientTypes.MetricStat(metric: metric, period: range.period, stat: d.stat),
                                                         returnData: true)
        }
        let (start, end) = window(range, now: now)
        return GetMetricDataInput(endTime: end, metricDataQueries: queries, scanBy: .timestampAscending, startTime: start)
    }

    /// `group` is db.sql_tokenized or db.wait_event.
    public static func dimensionKeys(resourceID: String, group: String, range: RDSTimeRange, now: Date, limit: Int = 10) -> DescribeDimensionKeysInput {
        let (start, end) = window(range, now: now)
        return DescribeDimensionKeysInput(endTime: end, groupBy: PIClientTypes.DimensionGroup(group: group, limit: limit), identifier: resourceID,
                                          metric: "db.load.avg", serviceType: .rds, startTime: start)
    }

    public static func loadMetric(resourceID: String, range: RDSTimeRange, now: Date) -> GetResourceMetricsInput {
        let (start, end) = window(range, now: now)
        return GetResourceMetricsInput(endTime: end, identifier: resourceID, metricQueries: [PIClientTypes.MetricQuery(metric: "db.load.avg")],
                                       periodInSeconds: range.period, serviceType: .rds, startTime: start)
    }

    /// Range ending at `now`, aligned down to the period so successive refreshes ask for the same buckets.
    static func window(_ range: RDSTimeRange, now: Date) -> (Date, Date) {
        let p = Double(range.period)
        let end = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / p).rounded(.down) * p)
        return (end.addingTimeInterval(-range.seconds), end)
    }
}

/// AWS SDK responses → the dashboard's models. Missing fields become nil / false.
public enum RDSMapping {
    public static func instances(_ output: DescribeDBInstancesOutput) -> [RDSInstanceInfo] {
        (output.dbInstances ?? []).compactMap(instance)
    }

    static func instance(_ o: RDSClientTypes.DBInstance) -> RDSInstanceInfo? {
        guard let id = o.dbInstanceIdentifier else { return nil }
        return RDSInstanceInfo(
            identifier: id,
            arn: o.dbInstanceArn,
            resourceID: o.dbiResourceId,
            engine: o.engine ?? "?",
            engineVersion: o.engineVersion,
            instanceClass: o.dbInstanceClass ?? "?",
            status: o.dbInstanceStatus ?? "unknown",
            multiAZ: o.multiAZ ?? false,
            availabilityZone: o.availabilityZone,
            secondaryAvailabilityZone: o.secondaryAvailabilityZone,
            endpoint: o.endpoint?.address,
            port: o.endpoint?.port,
            storageType: o.storageType,
            allocatedStorageGiB: o.allocatedStorage,
            maxAllocatedStorageGiB: o.maxAllocatedStorage,
            iops: o.iops,
            storageThroughputMiBps: o.storageThroughput,
            publiclyAccessible: o.publiclyAccessible ?? false,
            storageEncrypted: o.storageEncrypted ?? false,
            deletionProtection: o.deletionProtection ?? false,
            backupRetentionDays: o.backupRetentionPeriod,
            backupWindow: o.preferredBackupWindow,
            maintenanceWindow: o.preferredMaintenanceWindow,
            autoMinorVersionUpgrade: o.autoMinorVersionUpgrade,
            pendingModifiedValues: pending(o.pendingModifiedValues),
            caCertificate: o.caCertificateIdentifier ?? o.certificateDetails?.caIdentifier,
            caCertificateValidTill: o.certificateDetails?.validTill,
            parameterGroups: (o.dbParameterGroups ?? []).compactMap { g in
                g.dbParameterGroupName.map { RDSParameterGroup(name: $0, status: g.parameterApplyStatus) }
            },
            performanceInsightsEnabled: o.performanceInsightsEnabled ?? false,
            performanceInsightsRetentionDays: o.performanceInsightsRetentionPeriod,
            monitoringInterval: o.monitoringInterval,
            clusterIdentifier: o.dbClusterIdentifier,
            createdAt: o.instanceCreateTime,
            iamAuthentication: o.iamDatabaseAuthenticationEnabled
        )
    }

    /// Pending changes under their API names ("DBInstanceClass" → "db.r6g.xlarge"). The master password is left out.
    static func pending(_ p: RDSClientTypes.PendingModifiedValues?) -> [String: String] {
        guard let p else { return [:] }
        var out: [String: String] = [:]
        out["DBInstanceClass"] = p.dbInstanceClass
        out["DBInstanceIdentifier"] = p.dbInstanceIdentifier
        out["AllocatedStorage"] = p.allocatedStorage.map(String.init)
        out["StorageType"] = p.storageType
        out["Iops"] = p.iops.map(String.init)
        out["StorageThroughput"] = p.storageThroughput.map(String.init)
        out["EngineVersion"] = p.engineVersion
        out["MultiAZ"] = p.multiAZ.map { $0 ? "true" : "false" }
        out["Port"] = p.port.map(String.init)
        out["BackupRetentionPeriod"] = p.backupRetentionPeriod.map(String.init)
        out["CACertificateIdentifier"] = p.caCertificateIdentifier
        out["IAMDatabaseAuthenticationEnabled"] = p.iamDatabaseAuthenticationEnabled.map { $0 ? "true" : "false" }
        out["DBSubnetGroupName"] = p.dbSubnetGroupName
        out["LicenseModel"] = p.licenseModel
        if let logs = p.pendingCloudwatchLogsExports {
            out["PendingCloudwatchLogsExports.LogTypesToEnable"] = logs.logTypesToEnable.map { $0.joined(separator: ", ") }
            out["PendingCloudwatchLogsExports.LogTypesToDisable"] = logs.logTypesToDisable.map { $0.joined(separator: ", ") }
        }
        return out
    }

    static func pending(_ p: RDSClientTypes.ClusterPendingModifiedValues?) -> [String: String] {
        guard let p else { return [:] }
        var out: [String: String] = [:]
        out["DBClusterIdentifier"] = p.dbClusterIdentifier
        out["AllocatedStorage"] = p.allocatedStorage.map(String.init)
        out["StorageType"] = p.storageType
        out["Iops"] = p.iops.map(String.init)
        out["EngineVersion"] = p.engineVersion
        out["BackupRetentionPeriod"] = p.backupRetentionPeriod.map(String.init)
        out["IAMDatabaseAuthenticationEnabled"] = p.iamDatabaseAuthenticationEnabled.map { $0 ? "true" : "false" }
        return out
    }

    public static func clusters(_ output: DescribeDBClustersOutput) -> [RDSClusterInfo] {
        (output.dbClusters ?? []).compactMap(cluster)
    }

    static func cluster(_ o: RDSClientTypes.DBCluster) -> RDSClusterInfo? {
        guard let id = o.dbClusterIdentifier else { return nil }
        return RDSClusterInfo(
            identifier: id,
            arn: o.dbClusterArn,
            resourceID: o.dbClusterResourceId,
            engine: o.engine ?? "?",
            engineVersion: o.engineVersion,
            engineMode: o.engineMode,
            status: o.status ?? "unknown",
            multiAZ: o.multiAZ ?? false,
            endpoint: o.endpoint,
            readerEndpoint: o.readerEndpoint,
            port: o.port,
            members: (o.dbClusterMembers ?? []).compactMap { m in
                m.dbInstanceIdentifier.map {
                    RDSClusterMember(identifier: $0, isWriter: m.isClusterWriter ?? false,
                                     parameterGroupStatus: m.dbClusterParameterGroupStatus, promotionTier: m.promotionTier)
                }
            }
            // Writer first, then readers by name.
            .sorted { ($0.isWriter ? 0 : 1, $0.identifier) < ($1.isWriter ? 0 : 1, $1.identifier) },
            serverlessMinACU: o.serverlessV2ScalingConfiguration?.minCapacity,
            serverlessMaxACU: o.serverlessV2ScalingConfiguration?.maxCapacity,
            storageType: o.storageType,
            storageEncrypted: o.storageEncrypted ?? false,
            deletionProtection: o.deletionProtection ?? false,
            backupRetentionDays: o.backupRetentionPeriod,
            backupWindow: o.preferredBackupWindow,
            maintenanceWindow: o.preferredMaintenanceWindow,
            parameterGroup: o.dbClusterParameterGroup,
            pendingModifiedValues: pending(o.pendingModifiedValues),
            performanceInsightsEnabled: o.performanceInsightsEnabled,
            availabilityZones: o.availabilityZones ?? [],
            createdAt: o.clusterCreateTime
        )
    }

    public static func pendingActions(_ output: DescribePendingMaintenanceActionsOutput) -> [RDSPendingAction] {
        (output.pendingMaintenanceActions ?? []).flatMap { r in
            (r.pendingMaintenanceActionDetails ?? []).map { d in
                RDSPendingAction(resourceARN: r.resourceIdentifier ?? "?", action: d.action ?? "?", description: d.description,
                                 autoAppliedAfter: d.autoAppliedAfterDate, forcedApplyDate: d.forcedApplyDate,
                                 currentApplyDate: d.currentApplyDate, optInStatus: d.optInStatus)
            }
        }
    }

    /// Newest first.
    public static func events(_ output: DescribeEventsOutput) -> [RDSEvent] {
        (output.events ?? []).map { e in
            RDSEvent(date: e.date, message: e.message ?? "", sourceIdentifier: e.sourceIdentifier,
                     sourceType: e.sourceType?.rawValue, categories: e.eventCategories ?? [])
        }
        .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    /// Results matched back to the requested definitions (same order, unknown ids dropped; pages merged).
    public static func metricData(_ results: [CloudWatchClientTypes.MetricDataResult], definitions: [RDSMetricDefinition]) -> [RDSMetricSeries] {
        var byID: [String: (points: [RDSMetricPoint], status: String?)] = [:]
        for r in results {
            guard let id = r.id else { continue }
            var entry = byID[id] ?? ([], nil)
            for (t, v) in zip(r.timestamps ?? [], r.values ?? []) where v.isFinite {
                entry.points.append(RDSMetricPoint(date: t, value: v))
            }
            entry.status = r.statusCode?.rawValue ?? entry.status
            byID[id] = entry
        }
        return definitions.compactMap { d in
            guard let r = byID[d.id] else { return nil }
            return RDSMetricSeries(id: d.id, metricName: d.metricName, title: d.title, unit: d.unit,
                                   points: r.points.sorted { $0.date < $1.date }, statusCode: r.status)
        }
    }

    public static func topSQL(_ output: DescribeDimensionKeysOutput) -> [RDSTopSQL] {
        (output.keys ?? []).enumerated().compactMap { i, k in
            let dims = k.dimensions ?? [:]
            guard let statement = dims["db.sql_tokenized.statement"] else { return nil }
            return RDSTopSQL(id: dims["db.sql_tokenized.id"] ?? "\(i)", statement: statement, load: k.total ?? 0)
        }
        .sorted { $0.load > $1.load }
    }

    public static func waits(_ output: DescribeDimensionKeysOutput) -> [RDSWaitEvent] {
        (output.keys ?? []).compactMap { k in
            let dims = k.dimensions ?? [:]
            guard let name = dims["db.wait_event.name"] else { return nil }
            return RDSWaitEvent(name: name, type: dims["db.wait_event.type"], load: k.total ?? 0)
        }
        .sorted { $0.load > $1.load }
    }

    /// The first metric's data points (missing values skipped).
    public static func resourceMetric(_ output: GetResourceMetricsOutput) -> [RDSMetricPoint] {
        (output.metricList?.first?.dataPoints ?? []).compactMap { p in
            guard let d = p.timestamp, let v = p.value, v.isFinite else { return nil }
            return RDSMetricPoint(date: d, value: v)
        }
        .sorted { $0.date < $1.date }
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
    public let api: AWSRDSAPI

    public init(settings: AWSSettings, api: AWSRDSAPI) {
        self.settings = settings
        self.api = api
    }

    var identifier: String { settings.identifier ?? "" }

    /// Instance or cluster description, members, pending maintenance (whose failure only fills `pendingError`).
    public func overview() async throws -> RDSOverview {
        var result: RDSOverview
        if settings.isCluster {
            guard let cluster = RDSMapping.clusters(try await api.describeDBClusters(RDSRequests.describeCluster(identifier))).first else {
                throw AWSError.notFound("DB cluster \(identifier)")
            }
            let instances = RDSMapping.instances(try await api.describeDBInstances(RDSRequests.describeClusterInstances(identifier)))
            let order = cluster.members.map(\.identifier)
            result = RDSOverview(cluster: cluster,
                                 instances: instances.sorted { (order.firstIndex(of: $0.identifier) ?? .max) < (order.firstIndex(of: $1.identifier) ?? .max) })
        } else {
            let instances = RDSMapping.instances(try await api.describeDBInstances(RDSRequests.describeInstance(identifier)))
            guard !instances.isEmpty else { throw AWSError.notFound("DB instance \(identifier)") }
            result = RDSOverview(instances: instances)
        }
        do {
            let ownARN = settings.isCluster ? result.cluster?.arn : result.instances.first?.arn
            var pending = RDSMapping.pendingActions(try await api.describePendingMaintenanceActions(
                RDSRequests.pendingMaintenance(identifier, isCluster: settings.isCluster, arn: ownARN)))
            if settings.isCluster {
                // Instance-level actions (OS updates) are filed per member.
                for i in result.instances {
                    let output = try? await api.describePendingMaintenanceActions(RDSRequests.pendingMaintenance(i.identifier, isCluster: false, arn: i.arn))
                    pending += output.map(RDSMapping.pendingActions) ?? []
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

    /// Every page of GetMetricData (one page holds 100,800 points, so a second page is rare).
    public func metrics(target: RDSMetricTarget, range: RDSTimeRange, now: Date = Date()) async throws -> [RDSMetricSeries] {
        let defs = RDSMetricCatalog.definitions(for: target)
        var input = RDSRequests.metricData(defs, target: target, range: range, now: now)
        var results: [CloudWatchClientTypes.MetricDataResult] = []
        for _ in 0..<10 {
            let output = try await api.getMetricData(input)
            results += output.metricDataResults ?? []
            guard let next = output.nextToken, !next.isEmpty else { break }
            input.nextToken = next
        }
        return RDSMapping.metricData(results, definitions: defs)
    }

    /// Top SQL, waits and the load curve. Not called when Performance Insights is off (the caller knows from the description).
    public func performanceInsights(instance: RDSInstanceInfo, range: RDSTimeRange, now: Date = Date()) async throws -> RDSPerformanceInsights {
        guard instance.performanceInsightsEnabled, let rid = instance.resourceID else {
            return RDSPerformanceInsights(enabled: false, instanceID: instance.identifier)
        }
        // Top SQL is the main result: its failure fails the section. Waits and the load curve degrade to a note.
        async let sqlData = api.describeDimensionKeys(RDSRequests.dimensionKeys(resourceID: rid, group: "db.sql_tokenized", range: range, now: now))
        async let waitData = api.describeDimensionKeys(RDSRequests.dimensionKeys(resourceID: rid, group: "db.wait_event", range: range, now: now))
        async let loadData = api.getResourceMetrics(RDSRequests.loadMetric(resourceID: rid, range: range, now: now))
        var result = RDSPerformanceInsights(enabled: true, instanceID: instance.identifier)
        do {
            result.topSQL = RDSMapping.topSQL(try await sqlData)
        } catch {
            _ = try? await waitData
            _ = try? await loadData
            throw error
        }
        do { result.waits = RDSMapping.waits(try await waitData) } catch { result.errors.append("Wait events: \(error.localizedDescription)") }
        do { result.load = RDSMapping.resourceMetric(try await loadData) } catch { result.errors.append("DB load: \(error.localizedDescription)") }
        return result
    }

    /// Events of the instance / cluster (and, for a cluster, of `memberID`), newest first.
    public func events(range: RDSTimeRange, memberID: String? = nil) async throws -> [RDSEvent] {
        var events = RDSMapping.events(try await api.describeEvents(RDSRequests.events(identifier, isCluster: settings.isCluster, minutes: range.eventMinutes)))
        if settings.isCluster, let memberID {
            let member = try? await api.describeEvents(RDSRequests.events(memberID, isCluster: false, minutes: range.eventMinutes))
            events += member.map(RDSMapping.events) ?? []
            events.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        }
        return events
    }
}

/// IAM actions and the minimal policy, for settings screens and docs.
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
