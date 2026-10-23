import AWSCloudWatch
import AWSPI
import AWSRDS
import AppKit
import Smithy
import SmithyIdentity
import SwiftUI
import XCTest
import MTPCore
import MTPUIKit
@testable import FeatureInsights

final class RDSTests: XCTestCase {
    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? .current
        return c
    }()

    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        Self.utc.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min)) ?? .distantPast
    }

    // MARK: Mapping (AWS SDK responses → models)

    func testMapInstance() throws {
        let list = RDSMapping.instances(RDSFixtures.instance)
        XCTAssertEqual(list.count, 1)
        let i = try XCTUnwrap(list.first)
        XCTAssertEqual(i.identifier, "shop-prod")
        XCTAssertEqual(i.engine, "postgres")
        XCTAssertEqual(i.engineVersion, "16.4")
        XCTAssertEqual(i.instanceClass, "db.t4g.medium")
        XCTAssertTrue(i.isBurstable)
        XCTAssertFalse(i.isAurora)
        XCTAssertEqual(i.status, "available")
        XCTAssertTrue(i.multiAZ)
        XCTAssertEqual(i.availabilityZone, "eu-west-3a")
        XCTAssertEqual(i.secondaryAvailabilityZone, "eu-west-3b")
        XCTAssertEqual(i.endpoint, "shop-prod.c9akciq32xyz.eu-west-3.rds.amazonaws.com")
        XCTAssertEqual(i.port, 5432)
        XCTAssertEqual(i.storageType, "gp3")
        XCTAssertEqual(i.allocatedStorageGiB, 100)
        XCTAssertEqual(i.maxAllocatedStorageGiB, 500)
        XCTAssertEqual(i.iops, 3000)
        XCTAssertEqual(i.storageThroughputMiBps, 125)
        XCTAssertFalse(i.publiclyAccessible)
        XCTAssertTrue(i.storageEncrypted)
        XCTAssertTrue(i.deletionProtection)
        XCTAssertEqual(i.backupRetentionDays, 7)
        XCTAssertEqual(i.backupWindow, "02:00-02:30")
        XCTAssertEqual(i.maintenanceWindow, "sun:03:00-sun:03:30")
        XCTAssertEqual(i.pendingModifiedValues["DBInstanceClass"], "db.m7g.large")
        XCTAssertEqual(i.pendingModifiedValues["PendingCloudwatchLogsExports.LogTypesToEnable"], "postgresql")
        XCTAssertFalse(i.pendingModifiedValues.keys.contains { $0.lowercased().contains("password") }, "the master password is never shown")
        XCTAssertEqual(i.caCertificate, "rds-ca-2019")
        XCTAssertEqual(i.caCertificateValidTill, date(2026, 11, 30, 23, 59).addingTimeInterval(59))
        XCTAssertEqual(i.parameterGroups, [RDSParameterGroup(name: "shop-pg16", status: "pending-reboot")])
        XCTAssertTrue(i.performanceInsightsEnabled)
        XCTAssertEqual(i.performanceInsightsRetentionDays, 7)
        XCTAssertEqual(i.monitoringInterval, 60)
        XCTAssertEqual(i.resourceID, "db-ABCDEFGHIJKLMNOPQRSTUVWXY1")
        XCTAssertEqual(i.arn, "arn:aws:rds:eu-west-3:123456789012:db:shop-prod")
        XCTAssertNil(i.clusterIdentifier)
        XCTAssertEqual(try XCTUnwrap(i.createdAt).timeIntervalSince1970, date(2023, 3, 14, 9, 26).addingTimeInterval(53.512).timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(i.iamAuthentication, false)
    }

    func testMapAuroraCluster() throws {
        let c = try XCTUnwrap(RDSMapping.clusters(RDSFixtures.cluster).first)
        XCTAssertEqual(c.identifier, "app-aurora")
        XCTAssertEqual(c.engine, "aurora-postgresql")
        XCTAssertEqual(c.engineVersion, "15.8")
        XCTAssertEqual(c.engineMode, "provisioned")
        XCTAssertEqual(c.writer, "app-aurora-writer")
        XCTAssertEqual(c.members.map(\.identifier), ["app-aurora-writer", "app-aurora-reader-1"], "writer first")
        XCTAssertEqual(c.members.first?.parameterGroupStatus, "pending-reboot")
        XCTAssertEqual(c.serverlessMinACU, 0.5)
        XCTAssertEqual(c.serverlessMaxACU, 16)
        XCTAssertTrue(c.isServerlessV2)
        XCTAssertEqual(c.readerEndpoint, "app-aurora.cluster-ro-c1x2y3z4w5v6.eu-west-1.rds.amazonaws.com")
        XCTAssertEqual(c.backupRetentionDays, 14)
        XCTAssertEqual(c.parameterGroup, "app-aurora-pg15")
        XCTAssertEqual(c.resourceID, "cluster-ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        XCTAssertEqual(c.availabilityZones.count, 3)
        XCTAssertNil(c.performanceInsightsEnabled)

        let members = RDSMapping.instances(RDSFixtures.clusterInstances)
        XCTAssertEqual(members.map(\.identifier), ["app-aurora-writer", "app-aurora-reader-1"])
        XCTAssertTrue(members.allSatisfy { $0.isServerless && $0.isAurora && $0.clusterIdentifier == "app-aurora" })
        XCTAssertEqual(members.map(\.performanceInsightsEnabled), [true, false])
    }

    func testMapPendingAndEvents() throws {
        let p = RDSMapping.pendingActions(RDSFixtures.pending)
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(p.first?.action, "system-update")
        XCTAssertEqual(p.first?.resource, "shop-prod")
        XCTAssertEqual(p.first?.forcedApplyDate, date(2026, 12, 1))
        XCTAssertEqual(RDSMapping.pendingActions(RDSFixtures.noPending), [])

        let e = RDSMapping.events(RDSFixtures.events)
        XCTAssertEqual(e.map(\.message), ["Finished DB Instance backup", "Backing up DB instance", "Multi-AZ instance failover started."], "newest first")
        XCTAssertEqual(e.last?.categories, ["failover"])
        XCTAssertEqual(e.first?.sourceType, "db-instance")
    }

    func testMapMetrics() throws {
        let defs = RDSMetricCatalog.definitions(for: RDSMetricTarget(instanceID: "shop-prod", instanceClass: "db.t4g.medium"))
        let series = RDSMapping.metricData(RDSFixtures.metrics, definitions: defs)
        XCTAssertEqual(series.map(\.id), ["cpu", "memory", "readlatency"], "definition order, unknown ids dropped, missing ids absent")
        let cpu = try XCTUnwrap(series.first)
        XCTAssertEqual(cpu.points.map(\.value), [9.75, 12.0, 38.25, 41.5], "ascending, paginated chunks merged")
        XCTAssertEqual(cpu.latest, 41.5)
        XCTAssertEqual(cpu.maximum, 41.5)
        XCTAssertEqual(try XCTUnwrap(cpu.average), (9.75 + 12 + 38.25 + 41.5) / 4, accuracy: 1e-9)
        XCTAssertEqual(cpu.statusCode, "Complete")
        XCTAssertEqual(series[1].points, [])
        XCTAssertEqual(series[2].unit, .seconds)
        XCTAssertEqual(series[2].points.map(\.value), [0.0009, 0.00184], "NaN skipped")
    }

    func testMapPerformanceInsights() throws {
        let sql = RDSMapping.topSQL(RDSFixtures.topSQL)
        XCTAssertEqual(sql.count, 4)
        XCTAssertEqual(sql.first?.id, "AKIAIOSFODNN7SQL1")
        XCTAssertEqual(sql.first?.load, 1.8432)
        XCTAssertTrue(sql.first?.statement.hasPrefix("SELECT o.id") ?? false)
        let waits = RDSMapping.waits(RDSFixtures.waits)
        XCTAssertEqual(waits.map(\.name).prefix(2), ["CPU", "IO:DataFileRead"])
        XCTAssertEqual(waits[1].type, "IO")
        // Each mapping ignores the other grouping's keys.
        let merged = DescribeDimensionKeysOutput(keys: RDSFixtures.topSQLKeys + RDSFixtures.waitKeys)
        XCTAssertEqual(RDSMapping.topSQL(merged).count, 4)
        XCTAssertEqual(RDSMapping.waits(merged).count, 5)
        XCTAssertEqual(RDSMapping.resourceMetric(RDSFixtures.load).map(\.value), [1.0, 2.5], "sorted, point without value skipped")
    }

    func testMappingToleratesMissingFields() throws {
        let odd = DescribeDBInstancesOutput(dbInstances: [RDSClientTypes.DBInstance(dbInstanceIdentifier: "x"), RDSClientTypes.DBInstance()])
        let i = try XCTUnwrap(RDSMapping.instances(odd).first)
        XCTAssertEqual(RDSMapping.instances(odd).count, 1, "an instance without identifier is dropped")
        XCTAssertEqual(i.engine, "?")
        XCTAssertEqual(i.status, "unknown")
        XCTAssertFalse(i.multiAZ)
        XCTAssertNil(i.allocatedStorageGiB)
        XCTAssertEqual(i.pendingModifiedValues, [:])
        XCTAssertEqual(RDSMapping.instances(DescribeDBInstancesOutput()), [])
        XCTAssertEqual(RDSMapping.events(DescribeEventsOutput()), [])
        XCTAssertEqual(RDSMapping.resourceMetric(GetResourceMetricsOutput()), [])
    }

    // MARK: Errors

    func testErrorMapping() {
        func map(_ code: String, _ message: String, _ permission: String = "rds:DescribeDBInstances", profile: String? = "prod-ro") -> AWSError {
            AWSError.from(code: code, message: message, permission: permission, profile: profile)
        }
        let denied = "User: arn:aws:sts::123456789012:assumed-role/Developer/jane is not authorized to perform: rds:DescribeDBInstances on resource: "
            + "arn:aws:rds:eu-west-3:123456789012:db:shop-prod because no identity-based policy allows the rds:DescribeDBInstances action"
        XCTAssertEqual(map("AccessDenied", denied), .accessDenied(permission: "rds:DescribeDBInstances", message: denied))
        let pi = "User: arn:aws:sts::123456789012:assumed-role/Developer/jane is not authorized to perform: pi:DescribeDimensionKeys on resource: x"
        if case .accessDenied(let p, _) = map("NotAuthorizedException", pi, "pi:DescribeDimensionKeys") { XCTAssertEqual(p, "pi:DescribeDimensionKeys") } else { XCTFail() }
        // No action in the message: the one of the call.
        if case .accessDenied(let p, _) = map("AccessDeniedException", "Access denied", "rds:DescribeEvents") { XCTAssertEqual(p, "rds:DescribeEvents") } else { XCTFail() }
        XCTAssertEqual(map("ExpiredToken", "The security token included in the request is expired"), .expiredCredentials(profile: "prod-ro"))
        XCTAssertEqual(map("InvalidClientTokenId", "The security token included in the request is invalid."), .noCredentials(profile: "prod-ro"))
        XCTAssertEqual(map("DBInstanceNotFound", "DBInstance shop-prd not found."), .notFound("DBInstance shop-prd not found."))
        XCTAssertEqual(map("Throttling", "Rate exceeded"), .failed("Rate exceeded (Throttling)"))

        XCTAssertEqual(AWSError.credentials("ProfileAWSCredentialIdentityResolver: Profile with name prod-ro doesn't exist.", profile: "prod-ro"),
                       .unknownProfile("prod-ro"))
        XCTAssertEqual(AWSError.credentials("SSO token has expired, run aws sso login", profile: "prod-ro"), .ssoExpired(profile: "prod-ro"))
        XCTAssertEqual(AWSError.credentials("Failed to resolve credentials from profile: x.", profile: nil), .noCredentials(profile: nil))
        XCTAssertEqual(AWSError.from(CancellationError(), permission: "", profile: nil), .cancelled)
        XCTAssertEqual(AWSError.from(URLError(.notConnectedToInternet), permission: "", profile: nil),
                       .network(URLError(.notConnectedToInternet).localizedDescription))
        XCTAssertEqual(AWSError.from(AWSError.noConfigAccess, permission: "", profile: nil), .noConfigAccess)

        XCTAssertTrue(AWSError.ssoExpired(profile: "prod-ro").localizedDescription.contains("aws sso login --profile prod-ro"))
        XCTAssertTrue(AWSError.accessDenied(permission: "cloudwatch:GetMetricData", message: "").localizedDescription.contains("cloudwatch:GetMetricData"))
        XCTAssertTrue(AWSError.noConfigAccess.localizedDescription.contains("~/.aws"))
    }

    // MARK: Requests

    func testRequests() throws {
        let now = date(2026, 10, 23, 9, 2)
        let target = RDSMetricTarget(instanceID: "shop-prod", instanceClass: "db.t4g.medium")
        let defs = RDSMetricCatalog.definitions(for: target)
        let m = RDSRequests.metricData(defs, target: target, range: .day, now: now)
        let queries = try XCTUnwrap(m.metricDataQueries)
        XCTAssertEqual(queries.count, defs.count)
        let stat = try XCTUnwrap(queries.first?.metricStat)
        XCTAssertEqual(stat.period, 300)
        XCTAssertEqual(stat.stat, "Average")
        XCTAssertEqual(stat.metric?.namespace, "AWS/RDS")
        XCTAssertEqual(stat.metric?.dimensions?.first?.name, "DBInstanceIdentifier")
        XCTAssertEqual(stat.metric?.dimensions?.first?.value, "shop-prod")
        XCTAssertEqual(m.scanBy, .timestampAscending)
        // Aligned to the 5-minute period.
        XCTAssertEqual(m.endTime, date(2026, 10, 23, 9))
        XCTAssertEqual(m.startTime, date(2026, 10, 22, 9))
        for q in queries { XCTAssertNotNil(q.id?.range(of: "^[a-z][a-zA-Z0-9_]*$", options: .regularExpression)) }

        let pi = RDSRequests.dimensionKeys(resourceID: "db-ABC", group: "db.sql_tokenized", range: .hour, now: now)
        XCTAssertEqual(pi.serviceType, .rds)
        XCTAssertEqual(pi.identifier, "db-ABC")
        XCTAssertEqual(pi.groupBy?.group, "db.sql_tokenized")
        XCTAssertEqual(pi.groupBy?.limit, 10)
        XCTAssertEqual(pi.metric, "db.load.avg")
        let load = RDSRequests.loadMetric(resourceID: "db-ABC", range: .week, now: now)
        XCTAssertEqual(load.metricQueries?.first?.metric, "db.load.avg")
        XCTAssertEqual(load.periodInSeconds, RDSTimeRange.week.period)

        let events = RDSRequests.events("app-aurora", isCluster: true, minutes: 1440)
        XCTAssertEqual(events.sourceType, .dbCluster)
        XCTAssertEqual(events.sourceIdentifier, "app-aurora")
        XCTAssertEqual(events.duration, 1440)
        let pending = RDSRequests.pendingMaintenance("shop-prod", isCluster: false)
        XCTAssertEqual(pending.filters?.first?.name, "db-instance-id")
        XCTAssertEqual(pending.filters?.first?.values, ["shop-prod"])
        // With the ARN: no filter, so a policy scoped to this database is enough.
        let byARN = RDSRequests.pendingMaintenance("shop-prod", isCluster: false, arn: "arn:aws:rds:eu-west-3:1:db:shop-prod")
        XCTAssertEqual(byARN.resourceIdentifier, "arn:aws:rds:eu-west-3:1:db:shop-prod")
        XCTAssertNil(byARN.filters)
        XCTAssertEqual(RDSRequests.describeClusterInstances("app-aurora").filters?.first?.values, ["app-aurora"])
        XCTAssertEqual(RDSRequests.describeInstance("shop-prod").dbInstanceIdentifier, "shop-prod")
        XCTAssertEqual(RDSRequests.describeCluster("app-aurora").dbClusterIdentifier, "app-aurora")
    }

    // MARK: AWS folder & clients

    func testProfileNames() {
        let config = """
            [default]
            region = eu-west-3
            [profile prod-ro]
            role_arn = arn:aws:iam::1:role/ReadOnly
            source_profile = default
            [sso-session corp]
            sso_start_url = https://corp.awsapps.com/start
            [services local]
            [ profile  staging ]
            """
        XCTAssertEqual(AWSConfigFolder.profileNames(in: config, isConfig: true), ["default", "prod-ro", "staging"])
        XCTAssertEqual(AWSConfigFolder.profileNames(in: "[default]\naws_access_key_id = X\n[ci]\n", isConfig: false), ["default", "ci"])
    }

    func testFolderAccessIsRequiredAndRemembered() throws {
        let saved = AWSConfigFolder.bookmarkFile
        AWSConfigFolder.bookmarkFile = FileManager.default.temporaryDirectory.appendingPathComponent("aws-\(UUID().uuidString).bookmark")
        defer {
            AWSConfigFolder.revoke()
            AWSConfigFolder.bookmarkFile = saved
        }
        AWSConfigFolder.revoke()
        XCTAssertFalse(AWSConfigFolder.isGranted)
        XCTAssertNil(AWSConfigFolder.url())
        XCTAssertEqual(AWSConfigFolder.profileNames(), [], "nothing is read before access is granted")
        XCTAssertThrowsError(try AWSSDKRDSAPI(settings: AWSSettings(profile: "p", region: "eu-west-3", identifier: "db"))) { error in
            XCTAssertEqual(error as? AWSError, .noConfigAccess)
        }

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aws-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "[profile prod-ro]\nregion = eu-west-3\n".write(to: folder.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try "[default]\naws_access_key_id = AKIAEXAMPLE\naws_secret_access_key = example\n"
            .write(to: folder.appendingPathComponent("credentials"), atomically: true, encoding: .utf8)
        XCTAssertTrue(AWSConfigFolder.grant(folder))
        XCTAssertTrue(AWSConfigFolder.isGranted)
        XCTAssertEqual(AWSConfigFolder.url()?.standardizedFileURL.path, folder.standardizedFileURL.path)
        XCTAssertEqual(AWSConfigFolder.profileNames(), ["default", "prod-ro"])
        XCTAssertThrowsError(try AWSSDKRDSAPI(settings: AWSSettings(profile: "p", identifier: "db"))) { error in
            XCTAssertEqual(error as? AWSError, .missingRegion)
        }
        let api = try AWSSDKRDSAPI(settings: AWSSettings(profile: "prod-ro", region: "eu-west-3", identifier: "db"))
        XCTAssertEqual(api.profile, "prod-ro")
        XCTAssertEqual(try AWSSDKRDSAPI(settings: AWSSettings(region: "us-east-1", identifier: "db")).profile, "default")
    }

    /// Credentials are fetched once and reused until five minutes before they expire.
    func testCredentialCache() async throws {
        final class Counting: AWSCredentialIdentityResolver, @unchecked Sendable {
            var count = 0
            var expiration: Date?
            func getIdentity(identityProperties: Attributes?) async throws -> AWSCredentialIdentity {
                count += 1
                return AWSCredentialIdentity(accessKey: "AKIA\(count)", secret: "s", expiration: expiration)
            }
        }
        let source = Counting()
        source.expiration = Date().addingTimeInterval(3600)
        let cache = ExpiringCredentialCache(source: source)
        _ = try await cache.getIdentity(identityProperties: nil)
        let again = try await cache.getIdentity(identityProperties: nil)
        XCTAssertEqual(source.count, 1)
        XCTAssertEqual(again.accessKey, "AKIA1")

        let soon = Counting()
        soon.expiration = Date().addingTimeInterval(120)
        let expiring = ExpiringCredentialCache(source: soon)
        _ = try await expiring.getIdentity(identityProperties: nil)
        _ = try await expiring.getIdentity(identityProperties: nil)
        XCTAssertEqual(soon.count, 2, "less than five minutes left: fetched again")
    }

    func testMetricCatalog() {
        let plain = RDSMetricCatalog.definitions(for: RDSMetricTarget(instanceID: "a", instanceClass: "db.m6g.large")).map(\.metricName)
        XCTAssertEqual(plain, ["CPUUtilization", "DatabaseConnections", "FreeableMemory", "FreeStorageSpace", "ReadIOPS", "WriteIOPS",
                               "ReadLatency", "WriteLatency", "DiskQueueDepth", "NetworkReceiveThroughput", "NetworkTransmitThroughput"])
        XCTAssertTrue(RDSMetricCatalog.definitions(for: RDSMetricTarget(instanceID: "a", instanceClass: "db.t3.micro")).map(\.metricName).contains("CPUCreditBalance"))
        let writer = RDSMetricCatalog.definitions(for: RDSMetricTarget(instanceID: "w", clusterID: "c", instanceClass: "db.serverless",
                                                                       isAurora: true, isWriter: true, isServerless: true))
        let names = writer.map(\.metricName)
        XCTAssertFalse(names.contains("FreeStorageSpace"))
        XCTAssertTrue(names.contains("FreeLocalStorage"))
        XCTAssertTrue(names.contains("AuroraReplicaLagMaximum"))
        XCTAssertTrue(names.contains("ServerlessDatabaseCapacity"))
        XCTAssertTrue(names.contains("ACUUtilization"))
        XCTAssertEqual(writer.first { $0.metricName == "VolumeBytesUsed" }?.dimension, .cluster)
        let reader = RDSMetricCatalog.definitions(for: RDSMetricTarget(instanceID: "r", clusterID: "c", instanceClass: "db.r6g.large", isAurora: true, isWriter: false))
        XCTAssertTrue(reader.map(\.metricName).contains("AuroraReplicaLag"))
        // Cluster without instance details: cluster-level dimension.
        let clusterOnly = RDSMetricCatalog.definitions(for: RDSMetricTarget(instanceID: nil, clusterID: "c", isAurora: true))
        XCTAssertTrue(clusterOnly.allSatisfy { $0.dimension == .cluster })
    }

    // MARK: Units

    func testUnits() {
        XCTAssertEqual(RDSUnits.format(41.53, unit: .percent), "41.5%")
        XCTAssertEqual(RDSUnits.format(0.00184, unit: .seconds), "1.84 ms")
        XCTAssertEqual(RDSUnits.format(0.0005, unit: .seconds), "0.5 ms")
        XCTAssertEqual(RDSUnits.format(2.5, unit: .seconds), "2.5 s")
        XCTAssertEqual(RDSUnits.format(12, unit: .milliseconds), "12 ms")
        XCTAssertEqual(RDSUnits.format(1_610_612_736, unit: .bytes), "1.5 GB")
        XCTAssertEqual(RDSUnits.format(524_288_000, unit: .bytes), "500 MB")
        XCTAssertEqual(RDSUnits.format(2_097_152, unit: .bytesPerSecond), "2 MB/s")
        XCTAssertEqual(RDSUnits.format(1204, unit: .count).filter(\.isNumber), "1204", "grouped in the user's locale")
        XCTAssertEqual(RDSUnits.format(350.4, unit: .countPerSecond), "350/s")
        XCTAssertEqual(RDSUnits.format(nil, unit: .count), "—")
        XCTAssertEqual(RDSUnits.format(.nan, unit: .count), "—")
        XCTAssertEqual(RDSUnits.format(4, unit: .acu), "4 ACU")

        let s = RDSUnits.scale(for: .seconds, maxRaw: 0.004)
        XCTAssertEqual(s, RDSUnits.Scale(factor: 1000, suffix: "ms"))
        XCTAssertEqual(RDSUnits.axisLabel(0.004 * s.factor, suffix: s.suffix), "4 ms")
        XCTAssertEqual(RDSUnits.scale(for: .bytes, maxRaw: 1.4e9).suffix, "GB")
        XCTAssertEqual(RDSUnits.scale(for: .bytes, maxRaw: 9e8).suffix, "MB")
        XCTAssertEqual(RDSUnits.scale(for: .bytesPerSecond, maxRaw: 2048).suffix, "KB/s")
        XCTAssertEqual(RDSUnits.axisLabel(1.5, suffix: "GB"), "1.5 GB")
        XCTAssertEqual(RDSUnits.axisLabel(50, suffix: "%"), "50%")
        XCTAssertEqual(RDSUnits.gib(2048), "2 TiB")
        XCTAssertEqual(RDSUnits.gib(100), "100 GiB")
    }

    // MARK: Health warnings

    func testWarnings() throws {
        let now = date(2026, 10, 23, 9)
        var instance = try XCTUnwrap(RDSMapping.instances(RDSFixtures.instance).first)
        let pending = RDSMapping.pendingActions(RDSFixtures.pending)
        func series(_ name: String, _ v: Double) -> RDSMetricSeries {
            RDSMetricSeries(id: name, metricName: name, title: name, unit: .bytes, points: [RDSMetricPoint(date: now, value: v)])
        }
        // 10 GiB free of 100 GiB, 40 credits of 576.
        let metrics = [series("FreeStorageSpace", 10 * 1_073_741_824), series("CPUCreditBalance", 40)]
        let w = RDSHealth.warnings(overview: RDSOverview(instances: [instance], pending: pending), instanceID: nil, metrics: metrics, now: now)
        let text = w.map(\.text).joined(separator: "\n")
        XCTAssertTrue(text.contains("Pending maintenance on shop-prod: system-update"), text)
        XCTAssertTrue(text.contains("expires in 38 days"), text)
        XCTAssertTrue(text.contains("10.0% storage free"), text)
        XCTAssertTrue(text.contains("autoscaling is on"), text)
        XCTAssertTrue(text.contains("40 CPU credits left of 576"), text)
        XCTAssertTrue(text.contains("shop-pg16 on shop-prod"), text)
        XCTAssertTrue(text.contains("DBInstanceClass → db.m7g.large"), text)
        XCTAssertEqual(w.last?.severity, .info, "sorted by severity")

        // Healthy: nothing.
        instance.caCertificateValidTill = date(2027, 6, 1)
        instance.parameterGroups = [RDSParameterGroup(name: "shop-pg16", status: "in-sync")]
        instance.pendingModifiedValues = [:]
        let healthy = RDSHealth.warnings(overview: RDSOverview(instances: [instance]), instanceID: nil,
                                         metrics: [series("FreeStorageSpace", 60 * 1_073_741_824), series("CPUCreditBalance", 500)], now: now)
        XCTAssertEqual(healthy, [])

        // Expired certificate and a stopped instance are critical.
        instance.caCertificateValidTill = date(2026, 10, 1)
        instance.status = "stopped"
        let bad = RDSHealth.warnings(overview: RDSOverview(instances: [instance]), instanceID: nil, metrics: [], now: now)
        XCTAssertEqual(bad.map(\.severity), [.critical, .critical])

        // Aurora: cluster member pending reboot, no storage warning.
        let cluster = RDSMapping.clusters(RDSFixtures.cluster).first
        let members = RDSMapping.instances(RDSFixtures.clusterInstances)
        let aw = RDSHealth.warnings(overview: RDSOverview(cluster: cluster, instances: members), instanceID: nil,
                                    metrics: [series("FreeStorageSpace", 1)], now: now)
        XCTAssertEqual(aw.map(\.text), ["Parameter changes wait for a reboot: app-aurora-pg15 on app-aurora-writer."])
    }

    // MARK: Service (stub API)

    func testServiceInstance() async throws {
        let stub = StubAPI()
        stub.instances = .success(RDSFixtures.instance)
        stub.pending = .failure(AWSError.accessDenied(permission: "rds:DescribePendingMaintenanceActions", message: ""))
        stub.dimensionKeys = ["db.sql_tokenized": .success(RDSFixtures.topSQL), "db.wait_event": .success(RDSFixtures.waits)]
        stub.resourceMetrics = .failure(AWSError.accessDenied(permission: "pi:GetResourceMetrics", message: ""))
        let service = RDSService(settings: AWSSettings(profile: "p", region: "eu-west-3", identifier: "shop-prod"), api: stub)
        let o = try await service.overview()
        XCTAssertEqual(o.writer?.identifier, "shop-prod")
        XCTAssertNotNil(o.pendingError, "pending failure does not fail the description")
        // Pending maintenance is asked by ARN.
        if case .pending(let input) = stub.calls.first(where: { $0.name == "DescribePendingMaintenanceActions" }) {
            XCTAssertEqual(input.resourceIdentifier, "arn:aws:rds:eu-west-3:123456789012:db:shop-prod")
        } else { XCTFail("no pending call") }
        let pi = try await service.performanceInsights(instance: try XCTUnwrap(o.writer), range: .hour)
        XCTAssertTrue(pi.enabled)
        XCTAssertEqual(pi.topSQL.count, 4)
        XCTAssertEqual(pi.waits.count, 5)
        XCTAssertEqual(pi.errors.count, 1)
        XCTAssertTrue(pi.errors[0].contains("pi:GetResourceMetrics"))
        XCTAssertTrue(stub.calls.contains { if case .dimensionKeys(let i) = $0 { return i.identifier == "db-ABCDEFGHIJKLMNOPQRSTUVWXY1" }; return false })

        // PI off: no PI call at all.
        var off = try XCTUnwrap(o.writer)
        off.performanceInsightsEnabled = false
        let before = stub.calls.count
        let disabled = try await service.performanceInsights(instance: off, range: .hour)
        XCTAssertFalse(disabled.enabled)
        XCTAssertEqual(stub.calls.count, before)
    }

    func testServiceCluster() async throws {
        let stub = StubAPI()
        stub.clusters = .success(RDSFixtures.cluster)
        stub.instances = .success(RDSFixtures.clusterInstances)
        stub.pending = .success(RDSFixtures.noPending)
        stub.events = .success(RDSFixtures.events)
        let service = RDSService(settings: AWSSettings(region: "eu-west-1", identifier: "app-aurora", isCluster: true), api: stub)
        let o = try await service.overview()
        XCTAssertEqual(o.cluster?.identifier, "app-aurora")
        XCTAssertEqual(o.instances.map(\.identifier), ["app-aurora-writer", "app-aurora-reader-1"])
        XCTAssertEqual(o.writer?.identifier, "app-aurora-writer")
        XCTAssertEqual(o.instance("app-aurora-reader-1")?.identifier, "app-aurora-reader-1")
        XCTAssertEqual(stub.calls.filter { $0.name == "DescribePendingMaintenanceActions" }.count, 3, "cluster + each member")
        let events = try await service.events(range: .day, memberID: "app-aurora-reader-1")
        XCTAssertEqual(events.count, 6)
        let sources: [RDSClientTypes.SourceType?] = stub.calls.compactMap { if case .events(let i) = $0 { return i.sourceType }; return nil }
        XCTAssertEqual(sources, [.dbCluster, .dbInstance])
    }

    func testServiceFollowsMetricPages() async throws {
        let stub = StubAPI()
        let first = GetMetricDataOutput(metricDataResults: [RDSFixtures.metrics[0]], nextToken: "page-2")
        let second = GetMetricDataOutput(metricDataResults: [RDSFixtures.metrics[3]])
        stub.metricPages = [.success(first), .success(second)]
        let service = RDSService(settings: AWSSettings(region: "eu-west-3", identifier: "shop-prod"), api: stub)
        let series = try await service.metrics(target: RDSMetricTarget(instanceID: "shop-prod", instanceClass: "db.m6g.large"), range: .hour,
                                               now: date(2026, 10, 23, 9, 3))
        XCTAssertEqual(series.first { $0.id == "cpu" }?.points.count, 4)
        let tokens: [String?] = stub.calls.compactMap { if case .metrics(let i) = $0 { return i.nextToken }; return nil }
        XCTAssertEqual(tokens, [nil, "page-2"])
    }

    // MARK: Model (stub API end to end)

    @MainActor
    func makeContext(host: String = "shop-prod.c9akciq32xyz.eu-west-3.rds.amazonaws.com", aws: AWSSettings? = nil) -> StandaloneWorkspaceContext {
        var config = ConnectionConfig(name: "shop prod", driver: .postgres, host: host, port: 5432, user: "app", database: "shop",
                                      sslMode: .require, environment: .production)
        config.aws = aws
        return StandaloneWorkspaceContext(connection: config, secrets: ConnectionSecrets())
    }

    @MainActor
    func testModelLoadsAndReports() async throws {
        let stub = StubAPI.healthy(cluster: false)
        // One section failing must not break the others.
        stub.events = .failure(AWSError.accessDenied(permission: "rds:DescribeEvents", message: "Access denied"))
        let ctx = makeContext(aws: AWSSettings(profile: "prod-ro"))
        let settings = try XCTUnwrap(ctx.connection.effectiveAWS)
        XCTAssertEqual(settings.region, "eu-west-3")
        XCTAssertEqual(settings.identifier, "shop-prod")
        var built: AWSSettings?
        let model = RDSDashboardModel(context: ctx, settings: settings, makeAPI: { built = $0; return stub })
        XCTAssertEqual(built?.profile, "prod-ro")
        XCTAssertEqual(built?.region, "eu-west-3")
        XCTAssertNil(model.setupError)
        await model.refresh()
        XCTAssertNil(model.overview.error)
        XCTAssertEqual(model.overview.value?.writer?.identifier, "shop-prod")
        XCTAssertEqual(model.metrics.value?.count, 12)
        XCTAssertEqual(model.insights.value?.topSQL.count, 4)
        XCTAssertEqual(model.insights.value?.load.count, 360)
        XCTAssertNotNil(model.events.error)
        XCTAssertTrue(model.events.error?.contains("rds:DescribeEvents") ?? false, model.events.error ?? "")

        let report = model.reportForClaude()
        XCTAssertTrue(report.contains("instance shop-prod in eu-west-3"), report)
        XCTAssertTrue(report.contains("CPUUtilization: latest"), report)
        XCTAssertTrue(report.contains("Pending maintenance:"), report)
        XCTAssertTrue(report.contains("[1.84] SELECT o.id"), report)
        XCTAssertTrue(report.contains("IO:DataFileRead"), report)
        XCTAssertTrue(report.contains("## Events (last 24 hours)\nNot available:"), report)

        let items = model.claudeItems
        XCTAssertEqual(items.map(\.title), ["Analyze This Instance's Health", "Why Is CPU / Latency High?", "Is This Instance Sized Right?", "Explain the Top SQL"])
        XCTAssertTrue(items.allSatisfy { $0.disabledReason == nil })
        let request = items[0].request()
        XCTAssertEqual(request.attachments.first?.content, report)
        XCTAssertEqual(request.attachments.first?.containsRowData, false)
    }

    @MainActor
    func testModelNotConfigured() {
        let ctx = makeContext(host: "db.internal.example.com")
        let model = RDSDashboardModel(context: ctx)
        XCTAssertNil(model.settings)
        let incomplete = RDSDashboardModel(context: ctx, settings: AWSSettings(profile: "p"), api: StubAPI())
        XCTAssertNil(incomplete.settings)
    }

    /// Without access to ~/.aws the screen asks for it instead of failing every section.
    @MainActor
    func testModelWithoutFolderAccess() async {
        let ctx = makeContext(aws: AWSSettings(profile: "prod-ro"))
        let model = RDSDashboardModel(context: ctx, settings: ctx.connection.effectiveAWS, makeAPI: { _ in throw AWSError.noConfigAccess })
        XCTAssertNotNil(model.settings)
        XCTAssertEqual(model.setupError, .noConfigAccess)
        await model.refresh()
        XCTAssertNil(model.overview.value)
        XCTAssertNil(model.overview.error, "nothing was attempted")
    }

    // MARK: Render (MTP_RENDER_DIR)

    @MainActor
    func testRenderRDSDashboard() async throws {
        guard let dir = ProcessInfo.processInfo.environment["MTP_RENDER_DIR"], !dir.isEmpty else { throw XCTSkip("MTP_RENDER_DIR not set") }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        for cluster in [false, true] {
            let stub = StubAPI.healthy(cluster: cluster)
            let ctx = cluster
                ? makeContext(host: "app-aurora.cluster-c1x2y3z4w5v6.eu-west-1.rds.amazonaws.com", aws: AWSSettings(profile: "app-ro"))
                : makeContext(aws: AWSSettings(profile: "prod-ro"))
            let model = RDSDashboardModel(context: ctx, settings: ctx.connection.effectiveAWS, api: stub)
            await model.refresh()
            XCTAssertNil(model.overview.error)
            let name = cluster ? "rds-aurora" : "rds-instance"
            for dark in [false, true] {
                try renderHosted(RDSDashboardContent(model: model), size: CGSize(width: 1180, height: cluster ? 2350 : 2450), dark: dark,
                                 to: out.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
            }
            if !cluster {
                try renderHosted(RDSDashboardContent(model: model), size: CGSize(width: 760, height: 1400), dark: false,
                                 to: out.appendingPathComponent("rds-instance-narrow.png"))
                let cpu = try XCTUnwrap(model.series("CPUUtilization"))
                let hover = cpu.points[cpu.points.count * 72 / 100].date
                try renderHosted(RDSMetricChart(title: cpu.title, unit: cpu.unit, points: cpu.points, range: .sixHours, ceiling: 100, hover: hover)
                                    .padding(16).background(DS.Palette.canvas),
                                 size: CGSize(width: 420, height: 230), dark: true, to: out.appendingPathComponent("rds-chart-hover.png"))
            }
        }
        // Not configured and PI disabled states.
        let ctx = makeContext(host: "db.internal.example.com")
        try renderHosted(RDSDashboardContent(model: RDSDashboardModel(context: ctx)), size: CGSize(width: 900, height: 400), dark: false,
                         to: out.appendingPathComponent("rds-not-configured.png"))
        let noAccess = RDSDashboardModel(context: makeContext(aws: AWSSettings(profile: "prod-ro")),
                                         settings: makeContext(aws: AWSSettings(profile: "prod-ro")).connection.effectiveAWS,
                                         makeAPI: { _ in throw AWSError.noConfigAccess })
        for dark in [false, true] {
            try renderHosted(RDSDashboardContent(model: noAccess), size: CGSize(width: 900, height: 420), dark: dark,
                             to: out.appendingPathComponent("rds-no-access-\(dark ? "dark" : "light").png"))
        }
        let model = RDSDashboardModel(context: makeContext(), settings: makeContext().connection.effectiveAWS, api: StubAPI())
        model.insights = SectionState(value: RDSPerformanceInsights(enabled: false, instanceID: "shop-prod"))
        try renderHosted(RDSInsightsSection(model: model).padding(16).background(DS.Palette.canvas), size: CGSize(width: 900, height: 260),
                         dark: true, to: out.appendingPathComponent("rds-pi-disabled.png"))
    }

    @MainActor
    func renderHosted<V: View>(_ view: V, size: CGSize, dark: Bool, to url: URL) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: url)
        window.orderOut(nil)
    }
}
