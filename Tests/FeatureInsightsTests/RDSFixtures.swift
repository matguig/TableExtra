import Foundation
@testable import FeatureInsights

/// Canned AWS CLI v2 output (shapes copied from real `--output json` responses, values anonymised).
enum RDSFixtures {
    static let instance = """
    {
        "DBInstances": [
            {
                "DBInstanceIdentifier": "shop-prod",
                "DBInstanceClass": "db.t4g.medium",
                "Engine": "postgres",
                "DBInstanceStatus": "available",
                "MasterUsername": "postgres",
                "DBName": "shop",
                "Endpoint": {
                    "Address": "shop-prod.c9akciq32xyz.eu-west-3.rds.amazonaws.com",
                    "Port": 5432,
                    "HostedZoneId": "ZMESEXB7ZGGQ3"
                },
                "AllocatedStorage": 100,
                "InstanceCreateTime": "2023-03-14T09:26:53.512000+00:00",
                "PreferredBackupWindow": "02:00-02:30",
                "BackupRetentionPeriod": 7,
                "DBSecurityGroups": [],
                "VpcSecurityGroups": [{"VpcSecurityGroupId": "sg-0a1b2c3d4e5f", "Status": "active"}],
                "DBParameterGroups": [
                    {"DBParameterGroupName": "shop-pg16", "ParameterApplyStatus": "pending-reboot"}
                ],
                "AvailabilityZone": "eu-west-3a",
                "DBSubnetGroup": {"DBSubnetGroupName": "default-vpc-0abc", "SubnetGroupStatus": "Complete"},
                "PreferredMaintenanceWindow": "sun:03:00-sun:03:30",
                "PendingModifiedValues": {
                    "DBInstanceClass": "db.m7g.large",
                    "PendingCloudwatchLogsExports": {"LogTypesToEnable": ["postgresql"]}
                },
                "LatestRestorableTime": "2026-10-23T08:55:00+00:00",
                "MultiAZ": true,
                "EngineVersion": "16.4",
                "AutoMinorVersionUpgrade": true,
                "ReadReplicaDBInstanceIdentifiers": [],
                "LicenseModel": "postgresql-license",
                "OptionGroupMemberships": [{"OptionGroupName": "default:postgres-16", "Status": "in-sync"}],
                "SecondaryAvailabilityZone": "eu-west-3b",
                "PubliclyAccessible": false,
                "StorageType": "gp3",
                "Iops": 3000,
                "StorageThroughput": 125,
                "DbInstancePort": 0,
                "StorageEncrypted": true,
                "KmsKeyId": "arn:aws:kms:eu-west-3:123456789012:key/0f1e2d3c-aaaa-bbbb-cccc-1234567890ab",
                "DbiResourceId": "db-ABCDEFGHIJKLMNOPQRSTUVWXY1",
                "CACertificateIdentifier": "rds-ca-2019",
                "DomainMemberships": [],
                "CopyTagsToSnapshot": true,
                "MonitoringInterval": 60,
                "EnhancedMonitoringResourceArn": "arn:aws:logs:eu-west-3:123456789012:log-group:RDSOSMetrics:log-stream:db-ABCDEFGHIJKLMNOPQRSTUVWXY1",
                "MonitoringRoleArn": "arn:aws:iam::123456789012:role/rds-monitoring-role",
                "DBInstanceArn": "arn:aws:rds:eu-west-3:123456789012:db:shop-prod",
                "IAMDatabaseAuthenticationEnabled": false,
                "PerformanceInsightsEnabled": true,
                "PerformanceInsightsKMSKeyId": "arn:aws:kms:eu-west-3:123456789012:key/0f1e2d3c-aaaa-bbbb-cccc-1234567890ab",
                "PerformanceInsightsRetentionPeriod": 7,
                "DeletionProtection": true,
                "AssociatedRoles": [],
                "MaxAllocatedStorage": 500,
                "TagList": [{"Key": "env", "Value": "prod"}],
                "CustomerOwnedIpEnabled": false,
                "BackupTarget": "region",
                "NetworkType": "IPV4",
                "StorageVolumeStatus": "",
                "CertificateDetails": {
                    "CAIdentifier": "rds-ca-2019",
                    "ValidTill": "2026-11-30T23:59:59+00:00"
                },
                "DedicatedLogVolume": false,
                "EngineLifecycleSupport": "open-source-rds-extended-support"
            }
        ]
    }
    """

    static let cluster = """
    {
        "DBClusters": [
            {
                "AllocatedStorage": 1,
                "AvailabilityZones": ["eu-west-1a", "eu-west-1b", "eu-west-1c"],
                "BackupRetentionPeriod": 14,
                "DatabaseName": "app",
                "DBClusterIdentifier": "app-aurora",
                "DBClusterParameterGroup": "app-aurora-pg15",
                "DBSubnetGroup": "app-db-subnets",
                "Status": "available",
                "EarliestRestorableTime": "2026-10-09T02:31:12.100000+00:00",
                "Endpoint": "app-aurora.cluster-c1x2y3z4w5v6.eu-west-1.rds.amazonaws.com",
                "ReaderEndpoint": "app-aurora.cluster-ro-c1x2y3z4w5v6.eu-west-1.rds.amazonaws.com",
                "MultiAZ": true,
                "Engine": "aurora-postgresql",
                "EngineVersion": "15.8",
                "LatestRestorableTime": "2026-10-23T08:58:41.900000+00:00",
                "Port": 5432,
                "MasterUsername": "app_admin",
                "PreferredBackupWindow": "01:00-01:30",
                "PreferredMaintenanceWindow": "tue:04:00-tue:04:30",
                "ReadReplicaIdentifiers": [],
                "DBClusterMembers": [
                    {"DBInstanceIdentifier": "app-aurora-reader-1", "IsClusterWriter": false, "DBClusterParameterGroupStatus": "in-sync", "PromotionTier": 1},
                    {"DBInstanceIdentifier": "app-aurora-writer", "IsClusterWriter": true, "DBClusterParameterGroupStatus": "pending-reboot", "PromotionTier": 1}
                ],
                "VpcSecurityGroups": [{"VpcSecurityGroupId": "sg-0123456789abcdef0", "Status": "active"}],
                "HostedZoneId": "Z29XKXDKYMONMX",
                "StorageEncrypted": true,
                "KmsKeyId": "arn:aws:kms:eu-west-1:123456789012:key/11111111-2222-3333-4444-555555555555",
                "DbClusterResourceId": "cluster-ABCDEFGHIJKLMNOPQRSTUVWXYZ",
                "DBClusterArn": "arn:aws:rds:eu-west-1:123456789012:cluster:app-aurora",
                "AssociatedRoles": [],
                "IAMDatabaseAuthenticationEnabled": false,
                "ClusterCreateTime": "2024-02-01T10:12:00.351000+00:00",
                "EngineMode": "provisioned",
                "DeletionProtection": true,
                "HttpEndpointEnabled": false,
                "CopyTagsToSnapshot": true,
                "CrossAccountClone": false,
                "DomainMemberships": [],
                "TagList": [],
                "StorageType": "aurora",
                "AutoMinorVersionUpgrade": true,
                "ServerlessV2ScalingConfiguration": {"MinCapacity": 0.5, "MaxCapacity": 16.0},
                "NetworkType": "IPV4",
                "EngineLifecycleSupport": "open-source-rds-extended-support"
            }
        ]
    }
    """

    static func clusterInstance(_ id: String, writer: Bool, az: String, resource: String) -> String {
        """
            {
                "DBInstanceIdentifier": "\(id)",
                "DBInstanceClass": "db.serverless",
                "Engine": "aurora-postgresql",
                "DBInstanceStatus": "available",
                "Endpoint": {"Address": "\(id).c1x2y3z4w5v6.eu-west-1.rds.amazonaws.com", "Port": 5432, "HostedZoneId": "Z29XKXDKYMONMX"},
                "AllocatedStorage": 1,
                "InstanceCreateTime": "2024-02-01T10:20:11.000000+00:00",
                "PreferredBackupWindow": "01:00-01:30",
                "BackupRetentionPeriod": 14,
                "DBParameterGroups": [{"DBParameterGroupName": "default.aurora-postgresql15", "ParameterApplyStatus": "in-sync"}],
                "AvailabilityZone": "\(az)",
                "PreferredMaintenanceWindow": "tue:04:00-tue:04:30",
                "PendingModifiedValues": {},
                "MultiAZ": false,
                "EngineVersion": "15.8",
                "AutoMinorVersionUpgrade": true,
                "PubliclyAccessible": false,
                "StorageType": "aurora",
                "DbInstancePort": 0,
                "DBClusterIdentifier": "app-aurora",
                "StorageEncrypted": true,
                "DbiResourceId": "\(resource)",
                "CACertificateIdentifier": "rds-ca-rsa2048-g1",
                "MonitoringInterval": 0,
                "PromotionTier": 1,
                "DBInstanceArn": "arn:aws:rds:eu-west-1:123456789012:db:\(id)",
                "IAMDatabaseAuthenticationEnabled": false,
                "PerformanceInsightsEnabled": \(writer ? "true" : "false"),
                "PerformanceInsightsRetentionPeriod": 7,
                "DeletionProtection": false,
                "CertificateDetails": {"CAIdentifier": "rds-ca-rsa2048-g1", "ValidTill": "2027-02-01T10:18:43+00:00"}
            }
        """
    }

    static var clusterInstances: String {
        "{\"DBInstances\": [\n" + clusterInstance("app-aurora-writer", writer: true, az: "eu-west-1a", resource: "db-WRITERRESOURCEID0000000001") + ",\n"
            + clusterInstance("app-aurora-reader-1", writer: false, az: "eu-west-1b", resource: "db-READERRESOURCEID0000000001") + "\n]}"
    }

    static let pending = """
    {
        "PendingMaintenanceActions": [
            {
                "ResourceIdentifier": "arn:aws:rds:eu-west-3:123456789012:db:shop-prod",
                "PendingMaintenanceActionDetails": [
                    {
                        "Action": "system-update",
                        "AutoAppliedAfterDate": "2026-11-15T00:00:00+00:00",
                        "ForcedApplyDate": "2026-12-01T00:00:00+00:00",
                        "CurrentApplyDate": "2026-11-15T03:00:00+00:00",
                        "Description": "New Operating System update is available"
                    }
                ]
            }
        ]
    }
    """

    static let noPending = #"{"PendingMaintenanceActions": []}"#

    /// Descending timestamps (the API default), microseconds, an unrequested id and a pagination repeat.
    static let metrics = """
    {
        "MetricDataResults": [
            {
                "Id": "cpu",
                "Label": "CPUUtilization",
                "Timestamps": ["2026-10-23T09:02:00+00:00", "2026-10-23T09:01:00+00:00", "2026-10-23T09:00:00+00:00"],
                "Values": [41.5, 38.25, 12.0],
                "StatusCode": "Complete"
            },
            {
                "Id": "readlatency",
                "Label": "ReadLatency",
                "Timestamps": ["2026-10-23T09:01:00.000000+00:00", "2026-10-23T09:00:00.000000+00:00"],
                "Values": [0.00184, 0.0009],
                "StatusCode": "Complete"
            },
            {
                "Id": "memory",
                "Label": "FreeableMemory",
                "Timestamps": [],
                "Values": [],
                "StatusCode": "Complete"
            },
            {
                "Id": "cpu",
                "Label": "CPUUtilization",
                "Timestamps": ["2026-10-23T08:59:00+00:00"],
                "Values": [9.75],
                "StatusCode": "Complete"
            },
            {
                "Id": "other",
                "Label": "Whatever",
                "Timestamps": ["2026-10-23T09:00:00+00:00"],
                "Values": [1],
                "StatusCode": "Complete"
            }
        ],
        "Messages": []
    }
    """

    static let topSQL = """
    {
        "AlignedStartTime": "2026-10-23T03:00:00+00:00",
        "AlignedEndTime": "2026-10-23T09:00:00+00:00",
        "PartitionKeys": [],
        "Keys": [
            {
                "Dimensions": {
                    "db.sql_tokenized.statement": "SELECT o.id, o.status, c.email FROM orders o JOIN customers c ON c.id = o.customer_id WHERE o.created_at > $1 ORDER BY o.created_at DESC LIMIT $2",
                    "db.sql_tokenized.db_id": "pi-2372568224",
                    "db.sql_tokenized.id": "AKIAIOSFODNN7SQL1"
                },
                "Total": 1.8432
            },
            {
                "Dimensions": {
                    "db.sql_tokenized.statement": "UPDATE products SET stock = stock - $1 WHERE id = $2 AND stock >= $1",
                    "db.sql_tokenized.db_id": "pi-2372568224",
                    "db.sql_tokenized.id": "AKIAIOSFODNN7SQL2"
                },
                "Total": 0.4121
            },
            {
                "Dimensions": {
                    "db.sql_tokenized.statement": "INSERT INTO audit_log (actor, action, payload) VALUES ($1, $2, $3::jsonb)",
                    "db.sql_tokenized.db_id": "pi-2372568224",
                    "db.sql_tokenized.id": "AKIAIOSFODNN7SQL3"
                },
                "Total": 0.2007
            },
            {
                "Dimensions": {
                    "db.sql_tokenized.statement": "WITH recent AS (SELECT * FROM order_items WHERE order_id = ANY($1)) SELECT product_id, sum(quantity) FROM recent GROUP BY ?",
                    "db.sql_tokenized.db_id": "pi-2372568224",
                    "db.sql_tokenized.id": "AKIAIOSFODNN7SQL4"
                },
                "Total": 0.0915
            }
        ]
    }
    """

    static let waits = """
    {
        "AlignedStartTime": "2026-10-23T03:00:00+00:00",
        "AlignedEndTime": "2026-10-23T09:00:00+00:00",
        "PartitionKeys": [],
        "Keys": [
            {"Dimensions": {"db.wait_event.type": "CPU", "db.wait_event.name": "CPU"}, "Total": 1.2104},
            {"Dimensions": {"db.wait_event.type": "IO", "db.wait_event.name": "IO:DataFileRead"}, "Total": 0.7311},
            {"Dimensions": {"db.wait_event.type": "Lock", "db.wait_event.name": "Lock:transactionid"}, "Total": 0.3002},
            {"Dimensions": {"db.wait_event.type": "LWLock", "db.wait_event.name": "LWLock:WALWrite"}, "Total": 0.0821},
            {"Dimensions": {"db.wait_event.type": "Client", "db.wait_event.name": "Client:ClientRead"}, "Total": 0.0612}
        ]
    }
    """

    static let load = """
    {
        "AlignedStartTime": "2026-10-23T08:57:00+00:00",
        "AlignedEndTime": "2026-10-23T09:00:00+00:00",
        "Identifier": "db-ABCDEFGHIJKLMNOPQRSTUVWXY1",
        "MetricList": [
            {
                "Key": {"Metric": "db.load.avg"},
                "DataPoints": [
                    {"Timestamp": "2026-10-23T08:58:00+00:00", "Value": 2.5},
                    {"Timestamp": "2026-10-23T08:57:00+00:00", "Value": 1.0},
                    {"Timestamp": "2026-10-23T08:59:00+00:00"}
                ]
            }
        ]
    }
    """

    static let events = """
    {
        "Events": [
            {
                "SourceIdentifier": "shop-prod",
                "SourceType": "db-instance",
                "Message": "Backing up DB instance",
                "EventCategories": ["backup"],
                "Date": "2026-10-23T02:03:11.412000+00:00",
                "SourceArn": "arn:aws:rds:eu-west-3:123456789012:db:shop-prod"
            },
            {
                "SourceIdentifier": "shop-prod",
                "SourceType": "db-instance",
                "Message": "Finished DB Instance backup",
                "EventCategories": ["backup"],
                "Date": "2026-10-23T02:09:47.003000+00:00",
                "SourceArn": "arn:aws:rds:eu-west-3:123456789012:db:shop-prod"
            },
            {
                "SourceIdentifier": "shop-prod",
                "SourceType": "db-instance",
                "Message": "Multi-AZ instance failover started.",
                "EventCategories": ["failover"],
                "Date": "2026-10-22T17:41:02.120000+00:00",
                "SourceArn": "arn:aws:rds:eu-west-3:123456789012:db:shop-prod"
            }
        ]
    }
    """

    // MARK: Errors (stderr of AWS CLI v2, exit status 254 / 255)

    static let accessDeniedRDS = """

    An error occurred (AccessDenied) when calling the DescribeDBInstances operation: User: arn:aws:sts::123456789012:assumed-role/Developer/jane is not authorized to perform: rds:DescribeDBInstances on resource: arn:aws:rds:eu-west-3:123456789012:db:shop-prod because no identity-based policy allows the rds:DescribeDBInstances action
    """
    static let accessDeniedCloudWatch = """

    An error occurred (AccessDenied) when calling the GetMetricData operation: User: arn:aws:sts::123456789012:assumed-role/Developer/jane is not authorized to perform: cloudwatch:GetMetricData because no identity-based policy allows the cloudwatch:GetMetricData action
    """
    static let notAuthorizedPI = """

    An error occurred (NotAuthorizedException) when calling the DescribeDimensionKeys operation: User: arn:aws:sts::123456789012:assumed-role/Developer/jane is not authorized to perform: pi:DescribeDimensionKeys on resource: arn:aws:pi:eu-west-3:123456789012:metrics/rds/db-ABCDEFGHIJKLMNOPQRSTUVWXY1
    """
    static let accessDeniedNoAction = "An error occurred (AccessDeniedException) when calling the DescribeEvents operation: Access denied"
    static let ssoExpired = "Error when retrieving token from sso: Token has expired and refresh failed"
    static let ssoSession = "The SSO session associated with this profile has expired or is otherwise invalid. To refresh this SSO session run aws sso login with the corresponding profile."
    static let unknownProfile = "\nThe config profile (prod-ro) could not be found\n"
    static let noCredentials = "\nUnable to locate credentials. You can configure credentials by running \"aws configure\".\n"
    static let expiredToken = "\nAn error occurred (ExpiredToken) when calling the DescribeDBInstances operation: The security token included in the request is expired\n"
    static let notFound = "\nAn error occurred (DBInstanceNotFound) when calling the DescribeDBInstances operation: DBInstance shop-prd not found.\n"
    static let cliV1 = "usage: aws [options] <command> <subcommand> [<subcommand> ...] [parameters]\naws: error: Unknown options: --no-cli-pager\n"

    // MARK: Generated metrics (for the render and model tests)

    /// get-metric-data output for every definition, with plausible curves ending at `now`.
    static func metricData(_ defs: [RDSMetricDefinition], range: RDSTimeRange, now: Date) -> String {
        let n = Int(range.seconds) / range.period
        let f = ISO8601DateFormatter()
        var results: [[String: Any]] = []
        for d in defs {
            var stamps: [String] = []
            var values: [Double] = []
            for k in 0..<n {
                let t = now.addingTimeInterval(-Double(n - k) * Double(range.period))
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
                stamps.append(f.string(from: t))
                values.append(v)
            }
            results.append(["Id": d.id, "Label": d.metricName, "Timestamps": stamps.reversed() as [String], "Values": values.reversed() as [Double],
                            "StatusCode": "Complete"])
        }
        let data = (try? JSONSerialization.data(withJSONObject: ["MetricDataResults": results, "Messages": [] as [Any]], options: [.prettyPrinted])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func loadSeries(range: RDSTimeRange, now: Date) -> String {
        let n = Int(range.seconds) / range.period
        let f = ISO8601DateFormatter()
        let points = (0..<n).map { k -> String in
            let x = Double(k) / Double(max(n - 1, 1))
            let v = 0.9 + 0.8 * (sin(x * .pi * 6) * 0.5 + 0.5) + (abs(x - 0.72) < 0.03 ? 2.4 : 0)
            return "{\"Timestamp\": \"\(f.string(from: now.addingTimeInterval(-Double(n - k) * Double(range.period))))\", \"Value\": \(v)}"
        }
        return "{\"Identifier\": \"db-X\", \"MetricList\": [{\"Key\": {\"Metric\": \"db.load.avg\"}, \"DataPoints\": [\(points.joined(separator: ","))]}]}"
    }
}

/// A fake `aws` executable: logs its arguments and AWS_PAGER, answers `<service>-<operation>.json`
/// (exit 0) or `<service>-<operation>.err` (stderr, exit 254) from its directory.
struct FakeAWS {
    let dir: URL
    var executable: URL { dir.appendingPathComponent("aws") }
    var log: URL { dir.appendingPathComponent("calls.log") }

    static let script = """
    #!/bin/sh
    dir="$(cd "$(dirname "$0")" && pwd)"
    line="ARGS"
    for a in "$@"; do line="$line <$a>"; done
    # One write per call: concurrent invocations must not interleave.
    printf '%s\\nPAGER <%s> PROMPT <%s>\\n' "$line" "${AWS_PAGER-unset}" "${AWS_CLI_AUTO_PROMPT-unset}" >> "$dir/calls.log"
    key="$1-$2"
    if [ -f "$dir/$key.sleep" ]; then sleep "$(cat "$dir/$key.sleep")"; fi
    if [ -f "$dir/$key.err" ]; then cat "$dir/$key.err" >&2; exit 254; fi
    if [ -f "$dir/$key.json" ]; then cat "$dir/$key.json"; exit 0; fi
    echo "fake aws: no fixture for $key" >&2
    exit 2
    """

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("fake-aws-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Self.script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    func set(_ service: String, _ operation: String, json: String) throws {
        try json.write(to: dir.appendingPathComponent("\(service)-\(operation).json"), atomically: true, encoding: .utf8)
    }

    func fail(_ service: String, _ operation: String, stderr: String) throws {
        try stderr.write(to: dir.appendingPathComponent("\(service)-\(operation).err"), atomically: true, encoding: .utf8)
    }

    func sleep(_ service: String, _ operation: String, seconds: Int) throws {
        try "\(seconds)".write(to: dir.appendingPathComponent("\(service)-\(operation).sleep"), atomically: true, encoding: .utf8)
    }

    var calls: [String] { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }

    func remove() { try? FileManager.default.removeItem(at: dir) }

    /// Every fixture of a healthy single instance (or Aurora cluster), with metrics ending now.
    func installAll(cluster: Bool, range: RDSTimeRange = .sixHours, now: Date = Date()) throws {
        if cluster {
            try set("rds", "describe-db-clusters", json: RDSFixtures.cluster)
            try set("rds", "describe-db-instances", json: RDSFixtures.clusterInstances)
            let target = RDSMetricTarget(instanceID: "app-aurora-writer", clusterID: "app-aurora", instanceClass: "db.serverless",
                                         isAurora: true, isWriter: true, isServerless: true)
            try set("cloudwatch", "get-metric-data", json: RDSFixtures.metricData(RDSMetricCatalog.definitions(for: target), range: range, now: now))
            try set("rds", "describe-pending-maintenance-actions", json: RDSFixtures.noPending)
        } else {
            try set("rds", "describe-db-instances", json: RDSFixtures.instance)
            let target = RDSMetricTarget(instanceID: "shop-prod", instanceClass: "db.t4g.medium")
            try set("cloudwatch", "get-metric-data", json: RDSFixtures.metricData(RDSMetricCatalog.definitions(for: target), range: range, now: now))
            try set("rds", "describe-pending-maintenance-actions", json: RDSFixtures.pending)
        }
        try set("rds", "describe-events", json: RDSFixtures.events)
        // Both PI groupings go through describe-dimension-keys: answer with a merged key list.
        try set("pi", "describe-dimension-keys", json: Self.mergedKeys)
        try set("pi", "get-resource-metrics", json: RDSFixtures.loadSeries(range: range, now: now))
    }

    /// SQL and wait keys in one response; each parser keeps only its own dimension.
    static var mergedKeys: String {
        func keys(_ json: String) -> [Any] {
            ((try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any])?["Keys"] as? [Any] ?? []
        }
        let all = keys(RDSFixtures.topSQL) + keys(RDSFixtures.waits)
        let data = (try? JSONSerialization.data(withJSONObject: ["Keys": all])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
