import AWSCloudWatch
import AWSPI
import AWSRDS
import Foundation
@testable import FeatureInsights

/// Canned AWS SDK responses (values from real responses, anonymised).
enum RDSFixtures {
    static func date(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s) ?? .distantPast
    }

    static let instance = DescribeDBInstancesOutput(dbInstances: [
        RDSClientTypes.DBInstance(
            allocatedStorage: 100,
            autoMinorVersionUpgrade: true,
            availabilityZone: "eu-west-3a",
            backupRetentionPeriod: 7,
            caCertificateIdentifier: "rds-ca-2019",
            certificateDetails: RDSClientTypes.CertificateDetails(caIdentifier: "rds-ca-2019", validTill: date("2026-11-30T23:59:59Z")),
            dbInstanceArn: "arn:aws:rds:eu-west-3:123456789012:db:shop-prod",
            dbInstanceClass: "db.t4g.medium",
            dbInstanceIdentifier: "shop-prod",
            dbInstanceStatus: "available",
            dbParameterGroups: [RDSClientTypes.DBParameterGroupStatus(dbParameterGroupName: "shop-pg16", parameterApplyStatus: "pending-reboot")],
            dbiResourceId: "db-ABCDEFGHIJKLMNOPQRSTUVWXY1",
            deletionProtection: true,
            endpoint: RDSClientTypes.Endpoint(address: "shop-prod.c9akciq32xyz.eu-west-3.rds.amazonaws.com", hostedZoneId: "ZMESEXB7ZGGQ3", port: 5432),
            engine: "postgres",
            engineVersion: "16.4",
            iamDatabaseAuthenticationEnabled: false,
            instanceCreateTime: date("2023-03-14T09:26:53.512Z"),
            iops: 3000,
            maxAllocatedStorage: 500,
            monitoringInterval: 60,
            multiAZ: true,
            pendingModifiedValues: RDSClientTypes.PendingModifiedValues(
                dbInstanceClass: "db.m7g.large",
                masterUserPassword: "****",
                pendingCloudwatchLogsExports: RDSClientTypes.PendingCloudwatchLogsExports(logTypesToEnable: ["postgresql"])),
            performanceInsightsEnabled: true,
            performanceInsightsRetentionPeriod: 7,
            preferredBackupWindow: "02:00-02:30",
            preferredMaintenanceWindow: "sun:03:00-sun:03:30",
            publiclyAccessible: false,
            secondaryAvailabilityZone: "eu-west-3b",
            storageEncrypted: true,
            storageThroughput: 125,
            storageType: "gp3"
        ),
    ])

    static let cluster = DescribeDBClustersOutput(dbClusters: [
        RDSClientTypes.DBCluster(
            availabilityZones: ["eu-west-1a", "eu-west-1b", "eu-west-1c"],
            backupRetentionPeriod: 14,
            clusterCreateTime: date("2024-02-01T10:12:00.351Z"),
            dbClusterArn: "arn:aws:rds:eu-west-1:123456789012:cluster:app-aurora",
            dbClusterIdentifier: "app-aurora",
            dbClusterMembers: [
                RDSClientTypes.DBClusterMember(dbClusterParameterGroupStatus: "in-sync", dbInstanceIdentifier: "app-aurora-reader-1",
                                               isClusterWriter: false, promotionTier: 1),
                RDSClientTypes.DBClusterMember(dbClusterParameterGroupStatus: "pending-reboot", dbInstanceIdentifier: "app-aurora-writer",
                                               isClusterWriter: true, promotionTier: 1),
            ],
            dbClusterParameterGroup: "app-aurora-pg15",
            dbClusterResourceId: "cluster-ABCDEFGHIJKLMNOPQRSTUVWXYZ",
            deletionProtection: true,
            endpoint: "app-aurora.cluster-c1x2y3z4w5v6.eu-west-1.rds.amazonaws.com",
            engine: "aurora-postgresql",
            engineMode: "provisioned",
            engineVersion: "15.8",
            multiAZ: true,
            port: 5432,
            preferredBackupWindow: "01:00-01:30",
            preferredMaintenanceWindow: "tue:04:00-tue:04:30",
            readerEndpoint: "app-aurora.cluster-ro-c1x2y3z4w5v6.eu-west-1.rds.amazonaws.com",
            serverlessV2ScalingConfiguration: RDSClientTypes.ServerlessV2ScalingConfigurationInfo(maxCapacity: 16, minCapacity: 0.5),
            status: "available",
            storageEncrypted: true,
            storageType: "aurora"
        ),
    ])

    static func clusterInstance(_ id: String, writer: Bool, az: String, resource: String) -> RDSClientTypes.DBInstance {
        RDSClientTypes.DBInstance(
            allocatedStorage: 1,
            autoMinorVersionUpgrade: true,
            availabilityZone: az,
            backupRetentionPeriod: 14,
            caCertificateIdentifier: "rds-ca-rsa2048-g1",
            certificateDetails: RDSClientTypes.CertificateDetails(caIdentifier: "rds-ca-rsa2048-g1", validTill: date("2027-02-01T10:18:43Z")),
            dbClusterIdentifier: "app-aurora",
            dbInstanceArn: "arn:aws:rds:eu-west-1:123456789012:db:\(id)",
            dbInstanceClass: "db.serverless",
            dbInstanceIdentifier: id,
            dbInstanceStatus: "available",
            dbParameterGroups: [RDSClientTypes.DBParameterGroupStatus(dbParameterGroupName: "default.aurora-postgresql15", parameterApplyStatus: "in-sync")],
            dbiResourceId: resource,
            deletionProtection: false,
            endpoint: RDSClientTypes.Endpoint(address: "\(id).c1x2y3z4w5v6.eu-west-1.rds.amazonaws.com", port: 5432),
            engine: "aurora-postgresql",
            engineVersion: "15.8",
            iamDatabaseAuthenticationEnabled: false,
            instanceCreateTime: date("2024-02-01T10:20:11Z"),
            monitoringInterval: 0,
            multiAZ: false,
            pendingModifiedValues: RDSClientTypes.PendingModifiedValues(),
            performanceInsightsEnabled: writer,
            performanceInsightsRetentionPeriod: 7,
            preferredBackupWindow: "01:00-01:30",
            preferredMaintenanceWindow: "tue:04:00-tue:04:30",
            promotionTier: 1,
            publiclyAccessible: false,
            storageEncrypted: true,
            storageType: "aurora"
        )
    }

    /// Returned in the API's order (not writer first).
    static let clusterInstances = DescribeDBInstancesOutput(dbInstances: [
        clusterInstance("app-aurora-writer", writer: true, az: "eu-west-1a", resource: "db-WRITERRESOURCEID0000000001"),
        clusterInstance("app-aurora-reader-1", writer: false, az: "eu-west-1b", resource: "db-READERRESOURCEID0000000001"),
    ])

    static let pending = DescribePendingMaintenanceActionsOutput(pendingMaintenanceActions: [
        RDSClientTypes.ResourcePendingMaintenanceActions(
            pendingMaintenanceActionDetails: [
                RDSClientTypes.PendingMaintenanceAction(action: "system-update", autoAppliedAfterDate: date("2026-11-15T00:00:00Z"),
                                                        currentApplyDate: date("2026-11-15T03:00:00Z"),
                                                        description: "New Operating System update is available",
                                                        forcedApplyDate: date("2026-12-01T00:00:00Z")),
            ],
            resourceIdentifier: "arn:aws:rds:eu-west-3:123456789012:db:shop-prod"),
    ])

    static let noPending = DescribePendingMaintenanceActionsOutput(pendingMaintenanceActions: [])

    static let events = DescribeEventsOutput(events: [
        RDSClientTypes.Event(date: date("2026-10-23T02:03:11.412Z"), eventCategories: ["backup"], message: "Backing up DB instance",
                             sourceIdentifier: "shop-prod", sourceType: .dbInstance),
        RDSClientTypes.Event(date: date("2026-10-23T02:09:47.003Z"), eventCategories: ["backup"], message: "Finished DB Instance backup",
                             sourceIdentifier: "shop-prod", sourceType: .dbInstance),
        RDSClientTypes.Event(date: date("2026-10-22T17:41:02.120Z"), eventCategories: ["failover"], message: "Multi-AZ instance failover started.",
                             sourceIdentifier: "shop-prod", sourceType: .dbInstance),
    ])

    /// Descending timestamps (the API default), an unrequested id, a NaN and a pagination repeat.
    static let metrics: [CloudWatchClientTypes.MetricDataResult] = [
        CloudWatchClientTypes.MetricDataResult(id: "cpu", label: "CPUUtilization", statusCode: .complete,
                                               timestamps: [date("2026-10-23T09:02:00Z"), date("2026-10-23T09:01:00Z"), date("2026-10-23T09:00:00Z")],
                                               values: [41.5, 38.25, 12.0]),
        CloudWatchClientTypes.MetricDataResult(id: "readlatency", label: "ReadLatency", statusCode: .complete,
                                               timestamps: [date("2026-10-23T09:01:00Z"), date("2026-10-23T09:00:00Z"), date("2026-10-23T08:59:00Z")],
                                               values: [0.00184, 0.0009, .nan]),
        CloudWatchClientTypes.MetricDataResult(id: "memory", label: "FreeableMemory", statusCode: .complete, timestamps: [], values: []),
        CloudWatchClientTypes.MetricDataResult(id: "cpu", label: "CPUUtilization", statusCode: .complete,
                                               timestamps: [date("2026-10-23T08:59:00Z")], values: [9.75]),
        CloudWatchClientTypes.MetricDataResult(id: "other", label: "Whatever", statusCode: .complete,
                                               timestamps: [date("2026-10-23T09:00:00Z")], values: [1]),
    ]

    static let topSQLKeys: [PIClientTypes.DimensionKeyDescription] = [
        ("SELECT o.id, o.status, c.email FROM orders o JOIN customers c ON c.id = o.customer_id WHERE o.created_at > $1 ORDER BY o.created_at DESC LIMIT $2", "AKIAIOSFODNN7SQL1", 1.8432),
        ("UPDATE products SET stock = stock - $1 WHERE id = $2 AND stock >= $1", "AKIAIOSFODNN7SQL2", 0.4121),
        ("INSERT INTO audit_log (actor, action, payload) VALUES ($1, $2, $3::jsonb)", "AKIAIOSFODNN7SQL3", 0.2007),
        ("WITH recent AS (SELECT * FROM order_items WHERE order_id = ANY($1)) SELECT product_id, sum(quantity) FROM recent GROUP BY ?", "AKIAIOSFODNN7SQL4", 0.0915),
    ].map { statement, id, total in
        PIClientTypes.DimensionKeyDescription(dimensions: ["db.sql_tokenized.statement": statement, "db.sql_tokenized.db_id": "pi-2372568224",
                                                           "db.sql_tokenized.id": id], total: total)
    }

    static let waitKeys: [PIClientTypes.DimensionKeyDescription] = [
        ("CPU", "CPU", 1.2104), ("IO", "IO:DataFileRead", 0.7311), ("Lock", "Lock:transactionid", 0.3002),
        ("LWLock", "LWLock:WALWrite", 0.0821), ("Client", "Client:ClientRead", 0.0612),
    ].map { type, name, total in
        PIClientTypes.DimensionKeyDescription(dimensions: ["db.wait_event.type": type, "db.wait_event.name": name], total: total)
    }

    static let topSQL = DescribeDimensionKeysOutput(keys: topSQLKeys)
    static let waits = DescribeDimensionKeysOutput(keys: waitKeys)

    static let load = GetResourceMetricsOutput(identifier: "db-ABCDEFGHIJKLMNOPQRSTUVWXY1", metricList: [
        PIClientTypes.MetricKeyDataPoints(dataPoints: [
            PIClientTypes.DataPoint(timestamp: date("2026-10-23T08:58:00Z"), value: 2.5),
            PIClientTypes.DataPoint(timestamp: date("2026-10-23T08:57:00Z"), value: 1.0),
            PIClientTypes.DataPoint(timestamp: date("2026-10-23T08:59:00Z")),
        ]),
    ])

    // MARK: Generated metrics (for the render and model tests)

    /// GetMetricData results for every definition, with plausible curves ending at `now`.
    static func metricData(_ defs: [RDSMetricDefinition], range: RDSTimeRange, now: Date) -> GetMetricDataOutput {
        let n = Int(range.seconds) / range.period
        let results = defs.map { d -> CloudWatchClientTypes.MetricDataResult in
            var stamps: [Date] = []
            var values: [Double] = []
            for k in 0..<n {
                let x = Double(k) / Double(max(n - 1, 1))
                let wave = sin(x * .pi * 6) * 0.5 + 0.5
                let spike = abs(x - 0.72) < 0.03 ? 1.0 : 0.0
                let v: Double
                switch d.metricName {
                case "CPUUtilization": v = 18 + 22 * wave + 45 * spike
                case "DatabaseConnections": v = (42 + 18 * wave).rounded()
                case "FreeableMemory": v = 1.4e9 - 2.5e8 * wave
                case "FreeStorageSpace": v = 1.32e10 - 4e8 * x
                case "FreeLocalStorage": v = 2.9e10 - 1e9 * wave
                case "VolumeBytesUsed": v = 4.82e10 + 2e8 * x
                case "ReadIOPS": v = 120 + 300 * wave + 900 * spike
                case "WriteIOPS": v = 80 + 60 * wave
                case "ReadLatency": v = 0.0006 + 0.0012 * wave + 0.004 * spike
                case "WriteLatency": v = 0.0011 + 0.0006 * wave
                case "DiskQueueDepth": v = 0.2 + 0.6 * wave + 3 * spike
                case "NetworkReceiveThroughput": v = 2.1e6 + 1.5e6 * wave
                case "NetworkTransmitThroughput": v = 4.5e6 + 3e6 * wave
                case "CPUCreditBalance": v = 140 - 85 * x
                case "AuroraReplicaLagMaximum", "AuroraReplicaLag": v = 12 + 9 * wave
                case "ServerlessDatabaseCapacity": v = 2 + 3 * wave + 6 * spike
                case "ACUUtilization": v = 12 + 20 * wave + 40 * spike
                default: v = wave
                }
                stamps.append(now.addingTimeInterval(-Double(n - k) * Double(range.period)))
                values.append(v)
            }
            return CloudWatchClientTypes.MetricDataResult(id: d.id, label: d.metricName, statusCode: .complete,
                                                          timestamps: stamps.reversed(), values: values.reversed())
        }
        return GetMetricDataOutput(metricDataResults: results)
    }

    static func loadSeries(range: RDSTimeRange, now: Date) -> GetResourceMetricsOutput {
        let n = Int(range.seconds) / range.period
        let points = (0..<n).map { k -> PIClientTypes.DataPoint in
            let x = Double(k) / Double(max(n - 1, 1))
            let v = 0.9 + 0.8 * (sin(x * .pi * 6) * 0.5 + 0.5) + (abs(x - 0.72) < 0.03 ? 2.4 : 0)
            return PIClientTypes.DataPoint(timestamp: now.addingTimeInterval(-Double(n - k) * Double(range.period)), value: v)
        }
        return GetResourceMetricsOutput(identifier: "db-X", metricList: [PIClientTypes.MetricKeyDataPoints(dataPoints: points)])
    }
}

/// Answers each AWS operation from a table and records the inputs (no network).
final class StubAPI: AWSRDSAPI, @unchecked Sendable {
    enum Call {
        case instances(DescribeDBInstancesInput), clusters(DescribeDBClustersInput), pending(DescribePendingMaintenanceActionsInput)
        case events(DescribeEventsInput), metrics(GetMetricDataInput), dimensionKeys(DescribeDimensionKeysInput)
        case resourceMetrics(GetResourceMetricsInput), callerIdentity

        var name: String {
            switch self {
            case .instances: return "DescribeDBInstances"
            case .clusters: return "DescribeDBClusters"
            case .pending: return "DescribePendingMaintenanceActions"
            case .events: return "DescribeEvents"
            case .metrics: return "GetMetricData"
            case .dimensionKeys: return "DescribeDimensionKeys"
            case .resourceMetrics: return "GetResourceMetrics"
            case .callerIdentity: return "GetCallerIdentity"
            }
        }
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    var instances: Result<DescribeDBInstancesOutput, Error> = .failure(AWSError.failed("no stub"))
    var clusters: Result<DescribeDBClustersOutput, Error> = .failure(AWSError.failed("no stub"))
    var pending: Result<DescribePendingMaintenanceActionsOutput, Error> = .failure(AWSError.failed("no stub"))
    var events: Result<DescribeEventsOutput, Error> = .failure(AWSError.failed("no stub"))
    var metricPages: [Result<GetMetricDataOutput, Error>] = []
    /// Keyed by DimensionGroup.group.
    var dimensionKeys: [String: Result<DescribeDimensionKeysOutput, Error>] = [:]
    var resourceMetrics: Result<GetResourceMetricsOutput, Error> = .failure(AWSError.failed("no stub"))

    var calls: [Call] { lock.withLock { _calls } }

    private func record<T>(_ call: Call, _ answer: Result<T, Error>) throws -> T {
        lock.withLock { _calls.append(call) }
        return try answer.get()
    }

    func describeDBInstances(_ input: DescribeDBInstancesInput) async throws -> DescribeDBInstancesOutput { try record(.instances(input), instances) }
    func describeDBClusters(_ input: DescribeDBClustersInput) async throws -> DescribeDBClustersOutput { try record(.clusters(input), clusters) }
    func describePendingMaintenanceActions(_ input: DescribePendingMaintenanceActionsInput) async throws -> DescribePendingMaintenanceActionsOutput {
        try record(.pending(input), pending)
    }
    func describeEvents(_ input: DescribeEventsInput) async throws -> DescribeEventsOutput { try record(.events(input), events) }
    func getMetricData(_ input: GetMetricDataInput) async throws -> GetMetricDataOutput {
        let page = lock.withLock { _calls.filter { $0.name == "GetMetricData" }.count }
        return try record(.metrics(input), page < metricPages.count ? metricPages[page] : .success(GetMetricDataOutput()))
    }
    func describeDimensionKeys(_ input: DescribeDimensionKeysInput) async throws -> DescribeDimensionKeysOutput {
        try record(.dimensionKeys(input), dimensionKeys[input.groupBy?.group ?? ""] ?? .failure(AWSError.failed("no stub")))
    }
    func getResourceMetrics(_ input: GetResourceMetricsInput) async throws -> GetResourceMetricsOutput {
        try record(.resourceMetrics(input), resourceMetrics)
    }
    func callerIdentity() async throws -> String { try record(.callerIdentity, .success("arn:aws:sts::123456789012:assumed-role/ReadOnly/jane")) }

    /// Every response of a healthy single instance (or Aurora cluster), with metrics ending now.
    static func healthy(cluster: Bool, range: RDSTimeRange = .sixHours, now: Date = Date()) -> StubAPI {
        let s = StubAPI()
        let target: RDSMetricTarget
        if cluster {
            s.clusters = .success(RDSFixtures.cluster)
            s.instances = .success(RDSFixtures.clusterInstances)
            s.pending = .success(RDSFixtures.noPending)
            target = RDSMetricTarget(instanceID: "app-aurora-writer", clusterID: "app-aurora", instanceClass: "db.serverless",
                                     isAurora: true, isWriter: true, isServerless: true)
        } else {
            s.instances = .success(RDSFixtures.instance)
            s.pending = .success(RDSFixtures.pending)
            target = RDSMetricTarget(instanceID: "shop-prod", instanceClass: "db.t4g.medium")
        }
        s.metricPages = [.success(RDSFixtures.metricData(RDSMetricCatalog.definitions(for: target), range: range, now: now))]
        s.events = .success(RDSFixtures.events)
        s.dimensionKeys = ["db.sql_tokenized": .success(RDSFixtures.topSQL), "db.wait_event": .success(RDSFixtures.waits)]
        s.resourceMetrics = .success(RDSFixtures.loadSeries(range: range, now: now))
        return s
    }
}
