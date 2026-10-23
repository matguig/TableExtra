import Foundation

/// Pure parsers for AWS CLI v2 JSON output. Missing fields become nil / false; never crash on odd input.
public enum RDSParser {
    public struct ParseError: Error, LocalizedError, Equatable {
        public var message: String
        public var errorDescription: String? { message }
    }

    typealias Object = [String: Any]

    static func object(_ data: Data) throws -> Object {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? Object else {
            throw ParseError(message: "Unexpected AWS CLI output (not a JSON object)")
        }
        return o
    }

    // MARK: Instances & clusters

    public static func instances(_ data: Data) throws -> [RDSInstanceInfo] {
        let o = try object(data)
        return (o["DBInstances"] as? [Object] ?? []).compactMap(instance)
    }

    static func instance(_ o: Object) -> RDSInstanceInfo? {
        guard let id = o["DBInstanceIdentifier"] as? String else { return nil }
        let endpoint = o["Endpoint"] as? Object
        let cert = o["CertificateDetails"] as? Object
        return RDSInstanceInfo(
            identifier: id,
            arn: o["DBInstanceArn"] as? String,
            resourceID: o["DbiResourceId"] as? String,
            engine: o["Engine"] as? String ?? "?",
            engineVersion: o["EngineVersion"] as? String,
            instanceClass: o["DBInstanceClass"] as? String ?? "?",
            status: o["DBInstanceStatus"] as? String ?? "unknown",
            multiAZ: bool(o["MultiAZ"]),
            availabilityZone: o["AvailabilityZone"] as? String,
            secondaryAvailabilityZone: o["SecondaryAvailabilityZone"] as? String,
            endpoint: endpoint?["Address"] as? String,
            port: int(endpoint?["Port"]),
            storageType: o["StorageType"] as? String,
            allocatedStorageGiB: int(o["AllocatedStorage"]),
            maxAllocatedStorageGiB: int(o["MaxAllocatedStorage"]),
            iops: int(o["Iops"]),
            storageThroughputMiBps: int(o["StorageThroughput"]),
            publiclyAccessible: bool(o["PubliclyAccessible"]),
            storageEncrypted: bool(o["StorageEncrypted"]),
            deletionProtection: bool(o["DeletionProtection"]),
            backupRetentionDays: int(o["BackupRetentionPeriod"]),
            backupWindow: o["PreferredBackupWindow"] as? String,
            maintenanceWindow: o["PreferredMaintenanceWindow"] as? String,
            autoMinorVersionUpgrade: o["AutoMinorVersionUpgrade"] as? Bool,
            pendingModifiedValues: flatten(o["PendingModifiedValues"] as? Object ?? [:]),
            caCertificate: o["CACertificateIdentifier"] as? String ?? cert?["CAIdentifier"] as? String,
            caCertificateValidTill: date(cert?["ValidTill"]),
            parameterGroups: (o["DBParameterGroups"] as? [Object] ?? []).compactMap { g in
                (g["DBParameterGroupName"] as? String).map { RDSParameterGroup(name: $0, status: g["ParameterApplyStatus"] as? String) }
            },
            performanceInsightsEnabled: bool(o["PerformanceInsightsEnabled"]),
            performanceInsightsRetentionDays: int(o["PerformanceInsightsRetentionPeriod"]),
            monitoringInterval: int(o["MonitoringInterval"]),
            clusterIdentifier: o["DBClusterIdentifier"] as? String,
            createdAt: date(o["InstanceCreateTime"]),
            iamAuthentication: o["IAMDatabaseAuthenticationEnabled"] as? Bool
        )
    }

    public static func clusters(_ data: Data) throws -> [RDSClusterInfo] {
        let o = try object(data)
        return (o["DBClusters"] as? [Object] ?? []).compactMap(cluster)
    }

    static func cluster(_ o: Object) -> RDSClusterInfo? {
        guard let id = o["DBClusterIdentifier"] as? String else { return nil }
        let scaling = o["ServerlessV2ScalingConfiguration"] as? Object
        return RDSClusterInfo(
            identifier: id,
            arn: o["DBClusterArn"] as? String,
            resourceID: o["DbClusterResourceId"] as? String,
            engine: o["Engine"] as? String ?? "?",
            engineVersion: o["EngineVersion"] as? String,
            engineMode: o["EngineMode"] as? String,
            status: o["Status"] as? String ?? "unknown",
            multiAZ: bool(o["MultiAZ"]),
            endpoint: o["Endpoint"] as? String,
            readerEndpoint: o["ReaderEndpoint"] as? String,
            port: int(o["Port"]),
            members: (o["DBClusterMembers"] as? [Object] ?? []).compactMap { m in
                (m["DBInstanceIdentifier"] as? String).map {
                    RDSClusterMember(identifier: $0, isWriter: bool(m["IsClusterWriter"]),
                                     parameterGroupStatus: m["DBClusterParameterGroupStatus"] as? String, promotionTier: int(m["PromotionTier"]))
                }
            }
            // Writer first, then readers by name.
            .sorted { ($0.isWriter ? 0 : 1, $0.identifier) < ($1.isWriter ? 0 : 1, $1.identifier) },
            serverlessMinACU: double(scaling?["MinCapacity"]),
            serverlessMaxACU: double(scaling?["MaxCapacity"]),
            storageType: o["StorageType"] as? String,
            storageEncrypted: bool(o["StorageEncrypted"]),
            deletionProtection: bool(o["DeletionProtection"]),
            backupRetentionDays: int(o["BackupRetentionPeriod"]),
            backupWindow: o["PreferredBackupWindow"] as? String,
            maintenanceWindow: o["PreferredMaintenanceWindow"] as? String,
            parameterGroup: o["DBClusterParameterGroup"] as? String,
            pendingModifiedValues: flatten(o["PendingModifiedValues"] as? Object ?? [:]),
            performanceInsightsEnabled: o["PerformanceInsightsEnabled"] as? Bool,
            availabilityZones: o["AvailabilityZones"] as? [String] ?? [],
            createdAt: date(o["ClusterCreateTime"])
        )
    }

    public static func pendingActions(_ data: Data) throws -> [RDSPendingAction] {
        let o = try object(data)
        var out: [RDSPendingAction] = []
        for r in o["PendingMaintenanceActions"] as? [Object] ?? [] {
            let arn = r["ResourceIdentifier"] as? String ?? "?"
            for d in r["PendingMaintenanceActionDetails"] as? [Object] ?? [] {
                out.append(RDSPendingAction(resourceARN: arn, action: d["Action"] as? String ?? "?", description: d["Description"] as? String,
                                            autoAppliedAfter: date(d["AutoAppliedAfterDate"]), forcedApplyDate: date(d["ForcedApplyDate"]),
                                            currentApplyDate: date(d["CurrentApplyDate"]), optInStatus: d["OptInStatus"] as? String))
            }
        }
        return out
    }

    public static func events(_ data: Data) throws -> [RDSEvent] {
        let o = try object(data)
        return (o["Events"] as? [Object] ?? []).map { e in
            RDSEvent(date: date(e["Date"]), message: e["Message"] as? String ?? "", sourceIdentifier: e["SourceIdentifier"] as? String,
                     sourceType: e["SourceType"] as? String, categories: e["EventCategories"] as? [String] ?? [])
        }
        // Newest first.
        .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    // MARK: CloudWatch

    /// `get-metric-data` output matched back to the requested definitions (same order, unknown ids dropped).
    public static func metricData(_ data: Data, definitions: [RDSMetricDefinition]) throws -> [RDSMetricSeries] {
        let o = try object(data)
        var byID: [String: Object] = [:]
        for r in o["MetricDataResults"] as? [Object] ?? [] {
            if let id = r["Id"] as? String {
                // Paginated output repeats ids: merge their points.
                if var existing = byID[id] {
                    existing["Timestamps"] = (existing["Timestamps"] as? [Any] ?? []) + (r["Timestamps"] as? [Any] ?? [])
                    existing["Values"] = (existing["Values"] as? [Any] ?? []) + (r["Values"] as? [Any] ?? [])
                    byID[id] = existing
                } else {
                    byID[id] = r
                }
            }
        }
        return definitions.compactMap { d in
            guard let r = byID[d.id] else { return nil }
            let stamps = r["Timestamps"] as? [Any] ?? []
            let values = r["Values"] as? [Any] ?? []
            var points: [RDSMetricPoint] = []
            for (t, v) in zip(stamps, values) {
                if let date = date(t), let value = double(v), value.isFinite { points.append(RDSMetricPoint(date: date, value: value)) }
            }
            points.sort { $0.date < $1.date }
            return RDSMetricSeries(id: d.id, metricName: d.metricName, title: d.title, unit: d.unit, points: points,
                                   statusCode: r["StatusCode"] as? String)
        }
    }

    // MARK: Performance Insights

    public static func topSQL(_ data: Data) throws -> [RDSTopSQL] {
        let o = try object(data)
        return (o["Keys"] as? [Object] ?? []).enumerated().compactMap { i, k in
            let dims = k["Dimensions"] as? [String: Any] ?? [:]
            guard let statement = dims["db.sql_tokenized.statement"] as? String else { return nil }
            let id = dims["db.sql_tokenized.id"] as? String ?? "\(i)"
            return RDSTopSQL(id: id, statement: statement, load: double(k["Total"]) ?? 0)
        }
        .sorted { $0.load > $1.load }
    }

    public static func waits(_ data: Data) throws -> [RDSWaitEvent] {
        let o = try object(data)
        return (o["Keys"] as? [Object] ?? []).compactMap { k in
            let dims = k["Dimensions"] as? [String: Any] ?? [:]
            guard let name = dims["db.wait_event.name"] as? String else { return nil }
            return RDSWaitEvent(name: name, type: dims["db.wait_event.type"] as? String, load: double(k["Total"]) ?? 0)
        }
        .sorted { $0.load > $1.load }
    }

    /// `get-resource-metrics` → the first metric's data points (missing values skipped).
    public static func resourceMetric(_ data: Data) throws -> [RDSMetricPoint] {
        let o = try object(data)
        let first = (o["MetricList"] as? [Object])?.first
        return (first?["DataPoints"] as? [Object] ?? []).compactMap { p in
            guard let d = date(p["Timestamp"]), let v = double(p["Value"]), v.isFinite else { return nil }
            return RDSMetricPoint(date: d, value: v)
        }
        .sorted { $0.date < $1.date }
    }

    // MARK: Scalars

    /// JSON true/false (NSNumber 1/0 also bridges to Bool, so `is Bool` cannot tell them apart).
    static func isBoolean(_ n: NSNumber) -> Bool { CFGetTypeID(n) == CFBooleanGetTypeID() }

    static func bool(_ v: Any?) -> Bool {
        if let b = v as? Bool { return b }
        if let s = v as? String { return s.lowercased() == "true" }
        return false
    }

    static func int(_ v: Any?) -> Int? {
        if let n = v as? NSNumber, !isBoolean(n) {
            let d = n.doubleValue
            return d.isFinite && abs(d) < 9e18 ? Int(d) : nil
        }
        if let s = v as? String { return Int(s) }
        return nil
    }

    static func double(_ v: Any?) -> Double? {
        if let n = v as? NSNumber, !isBoolean(n) { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    /// AWS CLI v2 timestamps: "2024-05-01T10:00:00+00:00", "…T10:00:00.123456+00:00", "…Z", or epoch seconds.
    static func date(_ v: Any?) -> Date? {
        if let n = v as? NSNumber, !isBoolean(n) { return Date(timeIntervalSince1970: n.doubleValue) }
        guard let s = v as? String, !s.isEmpty else { return nil }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: s) { return d }
        // Drop fractional seconds (any number of digits) and retry.
        let stripped = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        if let d = plain.date(from: stripped) { return d }
        // No offset at all: UTC.
        return plain.date(from: stripped + "Z")
    }

    /// Nested values flattened to "Key" / "Parent.Key" → string.
    static func flatten(_ o: Object, prefix: String = "") -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in o {
            let key = prefix.isEmpty ? k : "\(prefix).\(k)"
            if let nested = v as? Object {
                out.merge(flatten(nested, prefix: key)) { a, _ in a }
            } else if let list = v as? [Any] {
                out[key] = list.map { "\($0)" }.joined(separator: ", ")
            } else if let n = v as? NSNumber {
                out[key] = isBoolean(n) ? (n.boolValue ? "true" : "false") : n.stringValue
            } else {
                out[key] = "\(v)"
            }
        }
        return out
    }
}
