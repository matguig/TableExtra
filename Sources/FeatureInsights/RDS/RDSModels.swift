import Foundation

/// Time window of the charts, Performance Insights and events.
public enum RDSTimeRange: String, CaseIterable, Identifiable, Sendable {
    case hour = "1h", sixHours = "6h", day = "24h", week = "7d"

    public var id: String { rawValue }
    public var title: String { rawValue }

    public var seconds: TimeInterval {
        switch self {
        case .hour: return 3600
        case .sixHours: return 6 * 3600
        case .day: return 86_400
        case .week: return 7 * 86_400
        }
    }

    /// CloudWatch period (seconds) per data point.
    public var period: Int {
        switch self {
        case .hour, .sixHours: return 60
        case .day: return 300
        case .week: return 3600
        }
    }

    /// Events are kept 14 days by RDS; short ranges still show the last day.
    public var eventMinutes: Int { self == .week ? 7 * 24 * 60 : 24 * 60 }
}

public struct RDSParameterGroup: Hashable, Sendable {
    public var name: String
    /// in-sync, pending-reboot, applying…
    public var status: String?
}

/// One DB instance (`describe-db-instances`).
public struct RDSInstanceInfo: Hashable, Sendable, Identifiable {
    public var identifier: String
    public var arn: String?
    /// DbiResourceId (db-ABC…), the Performance Insights identifier.
    public var resourceID: String?
    public var engine: String
    public var engineVersion: String?
    public var instanceClass: String
    public var status: String
    public var multiAZ: Bool
    public var availabilityZone: String?
    public var secondaryAvailabilityZone: String?
    public var endpoint: String?
    public var port: Int?
    public var storageType: String?
    public var allocatedStorageGiB: Int?
    /// Storage autoscaling ceiling; nil = autoscaling off.
    public var maxAllocatedStorageGiB: Int?
    public var iops: Int?
    public var storageThroughputMiBps: Int?
    public var publiclyAccessible: Bool
    public var storageEncrypted: Bool
    public var deletionProtection: Bool
    public var backupRetentionDays: Int?
    public var backupWindow: String?
    public var maintenanceWindow: String?
    public var autoMinorVersionUpgrade: Bool?
    /// Flattened PendingModifiedValues ("DBInstanceClass" → "db.r6g.xlarge").
    public var pendingModifiedValues: [String: String]
    public var caCertificate: String?
    public var caCertificateValidTill: Date?
    public var parameterGroups: [RDSParameterGroup]
    public var performanceInsightsEnabled: Bool
    public var performanceInsightsRetentionDays: Int?
    /// Enhanced Monitoring interval in seconds (0 = off).
    public var monitoringInterval: Int?
    public var clusterIdentifier: String?
    public var createdAt: Date?
    public var iamAuthentication: Bool?

    public var id: String { identifier }
    public var isBurstable: Bool { instanceClass.hasPrefix("db.t") }
    public var isServerless: Bool { instanceClass == "db.serverless" }
    public var isAurora: Bool { engine.hasPrefix("aurora") }
    public var allocatedStorageBytes: Double? { allocatedStorageGiB.map { Double($0) * 1_073_741_824 } }
}

public struct RDSClusterMember: Hashable, Sendable, Identifiable {
    public var identifier: String
    public var isWriter: Bool
    public var parameterGroupStatus: String?
    public var promotionTier: Int?
    public var id: String { identifier }
}

/// Aurora (or Multi-AZ DB) cluster (`describe-db-clusters`).
public struct RDSClusterInfo: Hashable, Sendable {
    public var identifier: String
    public var arn: String?
    public var resourceID: String?
    public var engine: String
    public var engineVersion: String?
    public var engineMode: String?
    public var status: String
    public var multiAZ: Bool
    public var endpoint: String?
    public var readerEndpoint: String?
    public var port: Int?
    public var members: [RDSClusterMember]
    public var serverlessMinACU: Double?
    public var serverlessMaxACU: Double?
    public var storageType: String?
    public var storageEncrypted: Bool
    public var deletionProtection: Bool
    public var backupRetentionDays: Int?
    public var backupWindow: String?
    public var maintenanceWindow: String?
    public var parameterGroup: String?
    public var pendingModifiedValues: [String: String]
    public var performanceInsightsEnabled: Bool?
    public var availabilityZones: [String]
    public var createdAt: Date?

    public var writer: String? { members.first { $0.isWriter }?.identifier }
    public var isServerlessV2: Bool { serverlessMaxACU != nil }
}

public struct RDSPendingAction: Hashable, Sendable, Identifiable {
    public var resourceARN: String
    public var action: String
    public var description: String?
    public var autoAppliedAfter: Date?
    public var forcedApplyDate: Date?
    public var currentApplyDate: Date?
    public var optInStatus: String?
    public var id: String { resourceARN + action }
    /// Last path component of the ARN (db / cluster identifier).
    public var resource: String { resourceARN.split(separator: ":").last.map(String.init) ?? resourceARN }
}

public struct RDSEvent: Hashable, Sendable, Identifiable {
    public var date: Date?
    public var message: String
    public var sourceIdentifier: String?
    public var sourceType: String?
    public var categories: [String]
    public var id: String { "\(date?.timeIntervalSince1970 ?? 0)|\(sourceIdentifier ?? "")|\(message)" }
}

/// What the instance / cluster description loaded: the main instance (writer for a cluster) and every member.
public struct RDSOverview: Sendable {
    public var cluster: RDSClusterInfo?
    /// The instance itself, or every member of the cluster.
    public var instances: [RDSInstanceInfo]
    public var pending: [RDSPendingAction]
    /// Pending-maintenance lookup error (the description itself loaded).
    public var pendingError: String?

    public init(cluster: RDSClusterInfo? = nil, instances: [RDSInstanceInfo], pending: [RDSPendingAction] = [], pendingError: String? = nil) {
        self.cluster = cluster
        self.instances = instances
        self.pending = pending
        self.pendingError = pendingError
    }

    public var writer: RDSInstanceInfo? {
        if let w = cluster?.writer, let i = instances.first(where: { $0.identifier == w }) { return i }
        return instances.first
    }

    public func instance(_ id: String?) -> RDSInstanceInfo? {
        guard let id else { return writer }
        return instances.first { $0.identifier == id } ?? writer
    }
}

// MARK: Metrics

public enum RDSMetricUnit: String, Sendable {
    case percent, bytes, bytesPerSecond, seconds, milliseconds, count, countPerSecond, acu
}

/// One CloudWatch metric the dashboard asks for.
public struct RDSMetricDefinition: Hashable, Sendable {
    public enum Dimension: String, Sendable { case instance = "DBInstanceIdentifier", cluster = "DBClusterIdentifier" }
    /// get-metric-data query id (lowercase first letter).
    public var id: String
    public var metricName: String
    public var title: String
    public var unit: RDSMetricUnit
    public var dimension: Dimension
    public var stat: String = "Average"
}

public struct RDSMetricPoint: Hashable, Sendable {
    public var date: Date
    public var value: Double
}

public struct RDSMetricSeries: Hashable, Sendable, Identifiable {
    public var id: String
    public var metricName: String
    public var title: String
    public var unit: RDSMetricUnit
    /// Ascending by date, raw CloudWatch values (seconds, bytes…).
    public var points: [RDSMetricPoint]
    public var statusCode: String?

    public var latest: Double? { points.last?.value }
    public var average: Double? { points.isEmpty ? nil : points.reduce(0) { $0 + $1.value } / Double(points.count) }
    public var maximum: Double? { points.map(\.value).max() }
    public var minimum: Double? { points.map(\.value).min() }
}

/// Which instance / cluster the metrics are read for.
public struct RDSMetricTarget: Hashable, Sendable {
    public var instanceID: String?
    public var clusterID: String?
    public var instanceClass: String?
    public var isAurora: Bool
    public var isWriter: Bool
    public var isServerless: Bool

    public init(instanceID: String?, clusterID: String? = nil, instanceClass: String? = nil, isAurora: Bool = false,
                isWriter: Bool = true, isServerless: Bool = false) {
        self.instanceID = instanceID
        self.clusterID = clusterID
        self.instanceClass = instanceClass
        self.isAurora = isAurora
        self.isWriter = isWriter
        self.isServerless = isServerless
    }

    public var isBurstable: Bool { instanceClass?.hasPrefix("db.t") ?? false }
}

// MARK: Performance Insights

public struct RDSTopSQL: Hashable, Sendable, Identifiable {
    public var id: String
    public var statement: String
    /// Average active sessions over the range.
    public var load: Double
}

public struct RDSWaitEvent: Hashable, Sendable, Identifiable {
    public var name: String
    public var type: String?
    public var load: Double
    public var id: String { (type ?? "") + "|" + name }
}

public struct RDSPerformanceInsights: Hashable, Sendable {
    /// False when Performance Insights is off for the instance (nothing else is loaded).
    public var enabled: Bool
    public var instanceID: String
    public var topSQL: [RDSTopSQL]
    public var waits: [RDSWaitEvent]
    /// db.load.avg over time.
    public var load: [RDSMetricPoint]
    /// Errors of the optional parts (load chart, waits) that did not stop the rest.
    public var errors: [String]

    public init(enabled: Bool, instanceID: String, topSQL: [RDSTopSQL] = [], waits: [RDSWaitEvent] = [], load: [RDSMetricPoint] = [],
                errors: [String] = []) {
        self.enabled = enabled
        self.instanceID = instanceID
        self.topSQL = topSQL
        self.waits = waits
        self.load = load
        self.errors = errors
    }

    public var averageLoad: Double? { load.isEmpty ? nil : load.reduce(0) { $0 + $1.value } / Double(load.count) }
}
