import AppKit
import SwiftUI
import XCTest
import MTPCore
import MTPUIKit
@testable import FeatureInsights

/// Records commands and answers from a table (no process).
final class StubRunner: AWSCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [AWSCommand] = []
    var answers: [String: Result<String, Error>]

    init(_ answers: [String: Result<String, Error>]) { self.answers = answers }

    var calls: [AWSCommand] { lock.withLock { _calls } }

    func json(_ service: String, _ operation: String, _ arguments: [String], settings: AWSSettings?) async throws -> Data {
        _ = try AWSCLI.arguments(service: service, operation: operation, arguments: arguments, settings: settings)
        let answer = lock.withLock {
            _calls.append(AWSCommand(service: service, operation: operation, arguments: arguments))
            return answers["\(service) \(operation)"]
        }
        switch answer {
        case .success(let s): return Data(s.utf8)
        case .failure(let e): throw e
        case nil: throw AWSCLIError.failed("no stub for \(service) \(operation)")
        }
    }
}

final class RDSTests: XCTestCase {
    func data(_ s: String) -> Data { Data(s.utf8) }

    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? .current
        return c
    }()

    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        Self.utc.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min)) ?? .distantPast
    }

    // MARK: Parsing

    func testParseInstance() throws {
        let list = try RDSParser.instances(data(RDSFixtures.instance))
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
        XCTAssertEqual(i.caCertificate, "rds-ca-2019")
        XCTAssertEqual(i.caCertificateValidTill, date(2026, 11, 30, 23, 59).addingTimeInterval(59))
        XCTAssertEqual(i.parameterGroups, [RDSParameterGroup(name: "shop-pg16", status: "pending-reboot")])
        XCTAssertTrue(i.performanceInsightsEnabled)
        XCTAssertEqual(i.performanceInsightsRetentionDays, 7)
        XCTAssertEqual(i.monitoringInterval, 60)
        XCTAssertEqual(i.resourceID, "db-ABCDEFGHIJKLMNOPQRSTUVWXY1")
        XCTAssertEqual(i.arn, "arn:aws:rds:eu-west-3:123456789012:db:shop-prod")
        XCTAssertNil(i.clusterIdentifier)
        // Fractional seconds with 6 digits.
        XCTAssertEqual(i.createdAt, date(2023, 3, 14, 9, 26).addingTimeInterval(53))
        XCTAssertEqual(i.iamAuthentication, false)
    }

    func testParseAuroraCluster() throws {
        let c = try XCTUnwrap(try RDSParser.clusters(data(RDSFixtures.cluster)).first)
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

        let members = try RDSParser.instances(data(RDSFixtures.clusterInstances))
        XCTAssertEqual(members.map(\.identifier), ["app-aurora-writer", "app-aurora-reader-1"])
        XCTAssertTrue(members.allSatisfy { $0.isServerless && $0.isAurora && $0.clusterIdentifier == "app-aurora" })
        XCTAssertEqual(members.map(\.performanceInsightsEnabled), [true, false])
    }

    func testParsePendingAndEvents() throws {
        let p = try RDSParser.pendingActions(data(RDSFixtures.pending))
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(p.first?.action, "system-update")
        XCTAssertEqual(p.first?.resource, "shop-prod")
        XCTAssertEqual(p.first?.forcedApplyDate, date(2026, 12, 1))
        XCTAssertEqual(try RDSParser.pendingActions(data(RDSFixtures.noPending)), [])

        let e = try RDSParser.events(data(RDSFixtures.events))
        XCTAssertEqual(e.map(\.message), ["Finished DB Instance backup", "Backing up DB instance", "Multi-AZ instance failover started."], "newest first")
        XCTAssertEqual(e.last?.categories, ["failover"])
    }

    func testParseMetrics() throws {
        let defs = RDSMetricCatalog.definitions(for: RDSMetricTarget(instanceID: "shop-prod", instanceClass: "db.t4g.medium"))
        let series = try RDSParser.metricData(data(RDSFixtures.metrics), definitions: defs)
        XCTAssertEqual(series.map(\.id), ["cpu", "memory", "readlatency"], "definition order, unknown ids dropped, missing ids absent")
        let cpu = try XCTUnwrap(series.first)
        XCTAssertEqual(cpu.points.map(\.value), [9.75, 12.0, 38.25, 41.5], "ascending, paginated chunks merged")
        XCTAssertEqual(cpu.latest, 41.5)
        XCTAssertEqual(cpu.maximum, 41.5)
        XCTAssertEqual(try XCTUnwrap(cpu.average), (9.75 + 12 + 38.25 + 41.5) / 4, accuracy: 1e-9)
        XCTAssertEqual(series[1].points, [])
        XCTAssertEqual(series[2].unit, .seconds)
        XCTAssertEqual(series[2].points.last?.value, 0.00184)
    }

    func testParsePerformanceInsights() throws {
        let sql = try RDSParser.topSQL(data(RDSFixtures.topSQL))
        XCTAssertEqual(sql.count, 4)
        XCTAssertEqual(sql.first?.id, "AKIAIOSFODNN7SQL1")
        XCTAssertEqual(sql.first?.load, 1.8432)
        XCTAssertTrue(sql.first?.statement.hasPrefix("SELECT o.id") ?? false)
        let waits = try RDSParser.waits(data(RDSFixtures.waits))
        XCTAssertEqual(waits.map(\.name).prefix(2), ["CPU", "IO:DataFileRead"])
        XCTAssertEqual(waits[1].type, "IO")
        // Each parser ignores the other grouping's keys.
        XCTAssertEqual(try RDSParser.topSQL(data(FakeAWS.mergedKeys)).count, 4)
        XCTAssertEqual(try RDSParser.waits(data(FakeAWS.mergedKeys)).count, 5)
        let load = try RDSParser.resourceMetric(data(RDSFixtures.load))
        XCTAssertEqual(load.map(\.value), [1.0, 2.5], "sorted, point without value skipped")
    }

    func testParserToleratesOddInput() throws {
        XCTAssertThrowsError(try RDSParser.instances(data("[1,2]")))
        XCTAssertThrowsError(try RDSParser.instances(data("not json")))
        XCTAssertEqual(try RDSParser.instances(data("{}")), [])
        let weird = #"{"DBInstances":[{"DBInstanceIdentifier":"x","AllocatedStorage":"20","MultiAZ":"true","Iops":1e30},{"NoId":1}]}"#
        let i = try XCTUnwrap(try RDSParser.instances(data(weird)).first)
        XCTAssertEqual(i.allocatedStorageGiB, 20)
        XCTAssertTrue(i.multiAZ)
        XCTAssertNil(i.iops)
        XCTAssertEqual(i.engine, "?")
        XCTAssertEqual(RDSParser.int(NSNumber(value: true)), nil, "a JSON boolean is not a number")
        XCTAssertEqual(RDSParser.date("2026-10-23T09:00:00Z"), date(2026, 10, 23, 9))
        XCTAssertEqual(RDSParser.date("2026-10-23T09:00:00.1+02:00"), date(2026, 10, 23, 7))
        XCTAssertEqual(RDSParser.date("2026-10-23T09:00:00"), date(2026, 10, 23, 9))
        XCTAssertNil(RDSParser.date("yesterday"))
    }

    // MARK: Errors

    func testErrorMapping() {
        func map(_ s: String, _ command: String = "rds describe-db-instances", profile: String? = "prod-ro") -> AWSCLIError {
            AWSCLI.mapError(s, command: command, profile: profile)
        }
        XCTAssertEqual(map(RDSFixtures.accessDeniedRDS), .accessDenied(permission: "rds:DescribeDBInstances", message: AWSCLI.firstLine(RDSFixtures.accessDeniedRDS)))
        if case .accessDenied(let p, _) = map(RDSFixtures.accessDeniedCloudWatch, "cloudwatch get-metric-data") { XCTAssertEqual(p, "cloudwatch:GetMetricData") } else { XCTFail() }
        if case .accessDenied(let p, _) = map(RDSFixtures.notAuthorizedPI, "pi describe-dimension-keys") { XCTAssertEqual(p, "pi:DescribeDimensionKeys") } else { XCTFail() }
        // No action in the message: taken from the command.
        if case .accessDenied(let p, _) = map(RDSFixtures.accessDeniedNoAction, "rds describe-events") { XCTAssertEqual(p, "rds:DescribeEvents") } else { XCTFail() }
        XCTAssertEqual(map(RDSFixtures.ssoExpired), .ssoExpired(profile: "prod-ro"))
        XCTAssertEqual(map(RDSFixtures.ssoSession), .ssoExpired(profile: "prod-ro"))
        XCTAssertEqual(map(RDSFixtures.unknownProfile), .unknownProfile("prod-ro"))
        XCTAssertEqual(map(RDSFixtures.noCredentials, profile: nil), .noCredentials(profile: nil))
        XCTAssertEqual(map(RDSFixtures.expiredToken), .expiredCredentials(profile: "prod-ro"))
        XCTAssertEqual(map(RDSFixtures.notFound), .notFound("DBInstance shop-prd not found."))
        XCTAssertEqual(map(RDSFixtures.cliV1), .cliTooOld)
        XCTAssertEqual(map("\nYou must specify a region. You can also configure your region by running \"aws configure\".\n"), .missingRegion)

        XCTAssertTrue(AWSCLIError.ssoExpired(profile: "prod-ro").localizedDescription.contains("aws sso login --profile prod-ro"))
        XCTAssertTrue(AWSCLIError.accessDenied(permission: "cloudwatch:GetMetricData", message: "").localizedDescription.contains("cloudwatch:GetMetricData"))
        XCTAssertTrue(AWSCLIError.notInstalled.localizedDescription.contains("brew install awscli"))
        XCTAssertTrue(AWSCLIError.unknownProfile("x").localizedDescription.contains("list-profiles"))
    }

    // MARK: Allowlist & arguments

    func testAllowlistRefusesWrites() {
        let s = AWSSettings(profile: "p", region: "eu-west-3", identifier: "db")
        for (svc, op) in [("rds", "delete-db-instance"), ("rds", "modify-db-instance"), ("rds", "reboot-db-instance"),
                          ("cloudwatch", "put-metric-data"), ("rds", "create-db-snapshot"), ("sts", "assume-role"),
                          ("configure", "set"), ("s3", "ls"), ("rds", "describe-db-instances ; rm"), ("", "")] {
            XCTAssertThrowsError(try AWSCLI.arguments(service: svc, operation: op, settings: s), "\(svc) \(op)") { e in
                guard case .notAllowed = e as? AWSCLIError else { return XCTFail("\(e)") }
            }
        }
        for extra in [["--endpoint-url", "http://evil"], ["--profile", "admin"], ["--region=us-east-1"], ["--output", "text"], ["--cli-input-json", "{}"]] {
            XCTAssertThrowsError(try AWSCLI.arguments(service: "rds", operation: "describe-db-instances", arguments: extra, settings: s), "\(extra)")
        }
        XCTAssertEqual(Set(AWSCLI.allowedCommands.keys), ["rds describe-db-instances", "rds describe-db-clusters", "rds describe-events",
                                                          "rds describe-pending-maintenance-actions", "cloudwatch get-metric-data",
                                                          "pi describe-dimension-keys", "pi get-resource-metrics", "configure list-profiles",
                                                          "sts get-caller-identity"])
    }

    func testArguments() throws {
        let s = AWSSettings(profile: "prod-ro", region: "eu-west-3", identifier: "shop-prod")
        XCTAssertEqual(try AWSCLI.arguments(service: "rds", operation: "describe-db-instances", arguments: ["--db-instance-identifier", "shop-prod"], settings: s),
                       ["rds", "describe-db-instances", "--db-instance-identifier", "shop-prod", "--profile", "prod-ro", "--region", "eu-west-3",
                        "--output", "json", "--no-cli-pager"])
        // No profile: the CLI's own resolution (AWS_PROFILE / default).
        XCTAssertEqual(try AWSCLI.arguments(service: "sts", operation: "get-caller-identity", settings: AWSSettings(region: "us-east-1")),
                       ["sts", "get-caller-identity", "--region", "us-east-1", "--output", "json", "--no-cli-pager"])
        let env = AWSCLI.environment(base: ["AWS_PAGER": "less", "HOME": "/Users/x", "AWS_DEFAULT_OUTPUT": "table"])
        XCTAssertEqual(env["AWS_PAGER"], "")
        XCTAssertNil(env["AWS_DEFAULT_OUTPUT"])
        XCTAssertTrue(env["PATH"]?.contains("/opt/homebrew/bin") ?? false)
    }

    func testCommands() throws {
        let now = date(2026, 10, 23, 9, 2)
        let target = RDSMetricTarget(instanceID: "shop-prod", instanceClass: "db.t4g.medium")
        let defs = RDSMetricCatalog.definitions(for: target)
        let c = RDSCommands.metricData(defs, target: target, range: .day, now: now)
        XCTAssertEqual(c.service, "cloudwatch")
        XCTAssertEqual(c.operation, "get-metric-data")
        let i = try XCTUnwrap(c.arguments.firstIndex(of: "--metric-data-queries"))
        let queries = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(c.arguments[i + 1].utf8)) as? [[String: Any]])
        XCTAssertEqual(queries.count, defs.count)
        let stat = try XCTUnwrap(queries.first?["MetricStat"] as? [String: Any])
        XCTAssertEqual(stat["Period"] as? Int, 300)
        XCTAssertEqual(stat["Stat"] as? String, "Average")
        let metric = try XCTUnwrap(stat["Metric"] as? [String: Any])
        XCTAssertEqual(metric["Namespace"] as? String, "AWS/RDS")
        XCTAssertEqual((metric["Dimensions"] as? [[String: String]])?.first, ["Name": "DBInstanceIdentifier", "Value": "shop-prod"])
        // Aligned to the 5-minute period.
        XCTAssertEqual(c.arguments[(c.arguments.firstIndex(of: "--end-time") ?? 0) + 1], "2026-10-23T09:00:00Z")
        XCTAssertEqual(c.arguments[(c.arguments.firstIndex(of: "--start-time") ?? 0) + 1], "2026-10-22T09:00:00Z")
        for q in queries { XCTAssertNotNil((q["Id"] as? String)?.range(of: "^[a-z][a-zA-Z0-9_]*$", options: .regularExpression)) }

        let pi = RDSCommands.dimensionKeys(resourceID: "db-ABC", group: "db.sql_tokenized", range: .hour, now: now)
        XCTAssertEqual(pi.arguments.prefix(4), ["--service-type", "RDS", "--identifier", "db-ABC"])
        XCTAssertTrue(pi.arguments.contains("{\"Group\":\"db.sql_tokenized\",\"Limit\":10}"))
        XCTAssertTrue(pi.arguments.contains("db.load.avg"))
        XCTAssertEqual(RDSCommands.events("app-aurora", isCluster: true, minutes: 1440).arguments,
                       ["--source-type", "db-cluster", "--source-identifier", "app-aurora", "--duration", "1440"])
        XCTAssertEqual(RDSCommands.pendingMaintenance("shop-prod", isCluster: false).arguments, ["--filters", "Name=db-instance-id,Values=shop-prod"])
        XCTAssertEqual(RDSCommands.describeClusterInstances("app-aurora").arguments, ["--filters", "Name=db-cluster-id,Values=app-aurora"])
        // Every command the service builds passes the allowlist.
        for cmd in [c, pi, RDSCommands.loadMetric(resourceID: "db-ABC", range: .week, now: now), RDSCommands.describeCluster("x"),
                    RDSCommands.describeInstance("x"), RDSCommands.events("x", isCluster: false, minutes: 60)] {
            XCTAssertNoThrow(try AWSCLI.arguments(service: cmd.service, operation: cmd.operation, arguments: cmd.arguments, settings: nil))
        }
        XCTAssertTrue(RDSCommands.describeInstance("shop-prod").commandLine(settings: AWSSettings(profile: "p", region: "r"))
            .hasPrefix("aws rds describe-db-instances --db-instance-identifier shop-prod --profile p --region r --output json --no-cli-pager"))
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
        var instance = try XCTUnwrap(try RDSParser.instances(data(RDSFixtures.instance)).first)
        let pending = try RDSParser.pendingActions(data(RDSFixtures.pending))
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
        let cluster = try RDSParser.clusters(data(RDSFixtures.cluster)).first
        let members = try RDSParser.instances(data(RDSFixtures.clusterInstances))
        let aw = RDSHealth.warnings(overview: RDSOverview(cluster: cluster, instances: members), instanceID: nil,
                                    metrics: [series("FreeStorageSpace", 1)], now: now)
        XCTAssertEqual(aw.map(\.text), ["Parameter changes wait for a reboot: app-aurora-pg15 on app-aurora-writer."])
    }

    // MARK: Service (stub runner)

    func testServiceInstance() async throws {
        let stub = StubRunner([
            "rds describe-db-instances": .success(RDSFixtures.instance),
            "rds describe-pending-maintenance-actions": .failure(AWSCLIError.accessDenied(permission: "rds:DescribePendingMaintenanceActions", message: "")),
            "pi describe-dimension-keys": .success(FakeAWS.mergedKeys),
            "pi get-resource-metrics": .failure(AWSCLIError.accessDenied(permission: "pi:GetResourceMetrics", message: "")),
        ])
        let service = RDSService(settings: AWSSettings(profile: "p", region: "eu-west-3", identifier: "shop-prod"), runner: stub)
        let o = try await service.overview()
        XCTAssertEqual(o.writer?.identifier, "shop-prod")
        XCTAssertNotNil(o.pendingError, "pending failure does not fail the description")
        let pi = try await service.performanceInsights(instance: try XCTUnwrap(o.writer), range: .hour)
        XCTAssertTrue(pi.enabled)
        XCTAssertEqual(pi.topSQL.count, 4)
        XCTAssertEqual(pi.waits.count, 5)
        XCTAssertEqual(pi.errors.count, 1)
        XCTAssertTrue(pi.errors[0].contains("pi:GetResourceMetrics"))
        XCTAssertTrue(stub.calls.contains { $0.arguments.contains("db-ABCDEFGHIJKLMNOPQRSTUVWXY1") })

        // PI off: no PI call at all.
        var off = try XCTUnwrap(o.writer)
        off.performanceInsightsEnabled = false
        let before = stub.calls.count
        let disabled = try await service.performanceInsights(instance: off, range: .hour)
        XCTAssertFalse(disabled.enabled)
        XCTAssertEqual(stub.calls.count, before)
    }

    func testServiceCluster() async throws {
        let stub = StubRunner([
            "rds describe-db-clusters": .success(RDSFixtures.cluster),
            "rds describe-db-instances": .success(RDSFixtures.clusterInstances),
            "rds describe-pending-maintenance-actions": .success(RDSFixtures.noPending),
            "rds describe-events": .success(RDSFixtures.events),
        ])
        let service = RDSService(settings: AWSSettings(region: "eu-west-1", identifier: "app-aurora", isCluster: true), runner: stub)
        let o = try await service.overview()
        XCTAssertEqual(o.cluster?.identifier, "app-aurora")
        XCTAssertEqual(o.instances.map(\.identifier), ["app-aurora-writer", "app-aurora-reader-1"])
        XCTAssertEqual(o.writer?.identifier, "app-aurora-writer")
        XCTAssertEqual(o.instance("app-aurora-reader-1")?.identifier, "app-aurora-reader-1")
        XCTAssertEqual(stub.calls.filter { $0.operation == "describe-pending-maintenance-actions" }.count, 3, "cluster + each member")
        let events = try await service.events(range: .day, memberID: "app-aurora-reader-1")
        XCTAssertEqual(events.count, 6)
        XCTAssertEqual(stub.calls.filter { $0.operation == "describe-events" }.map { $0.arguments[1] }, ["db-cluster", "db-instance"])
    }

    // MARK: Runner with a fake aws executable

    func testRunnerWithFakeScript() async throws {
        let fake = try FakeAWS()
        defer { fake.remove() }
        try fake.set("rds", "describe-db-instances", json: RDSFixtures.instance)
        try fake.set("sts", "get-caller-identity", json: #"{"UserId": "AROAEXAMPLE:jane", "Account": "123456789012", "Arn": "arn:aws:sts::123456789012:assumed-role/ReadOnly/jane"}"#)
        try fake.set("configure", "list-profiles", json: "default\nprod-ro\n\nstaging\n")
        let cli = AWSCLI(executableURL: fake.executable)
        let settings = AWSSettings(profile: "prod-ro", region: "eu-west-3", identifier: "shop-prod")

        let d = try await cli.json("rds", "describe-db-instances", ["--db-instance-identifier", "shop-prod"], settings: settings)
        XCTAssertEqual(try RDSParser.instances(d).first?.identifier, "shop-prod")
        XCTAssertEqual(fake.calls.first,
                       "ARGS <rds> <describe-db-instances> <--db-instance-identifier> <shop-prod> <--profile> <prod-ro> <--region> <eu-west-3> <--output> <json> <--no-cli-pager>")
        XCTAssertEqual(fake.calls.dropFirst().first, "PAGER <> PROMPT <off>")

        let who = try await cli.callerIdentity(settings)
        XCTAssertEqual(who, "arn:aws:sts::123456789012:assumed-role/ReadOnly/jane (account 123456789012)")
        let profiles = await cli.listProfiles()
        XCTAssertEqual(profiles, ["default", "prod-ro", "staging"])

        // Errors from stderr.
        try fake.fail("sts", "get-caller-identity", stderr: RDSFixtures.ssoExpired)
        do {
            _ = try await cli.callerIdentity(settings)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? AWSCLIError, .ssoExpired(profile: "prod-ro"))
            XCTAssertTrue(error.localizedDescription.contains("aws sso login --profile prod-ro"))
        }
        try fake.fail("rds", "describe-db-clusters", stderr: RDSFixtures.accessDeniedRDS)
        do {
            _ = try await cli.json("rds", "describe-db-clusters", [], settings: settings)
            XCTFail("expected an error")
        } catch {
            guard case .accessDenied(let p, _) = error as? AWSCLIError else { return XCTFail("\(error)") }
            XCTAssertEqual(p, "rds:DescribeDBInstances")
        }

        // Refused before launching: nothing logged.
        let count = fake.calls.count
        do {
            _ = try await cli.json("rds", "delete-db-instance", ["--db-instance-identifier", "shop-prod"], settings: settings)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? AWSCLIError, .notAllowed("rds delete-db-instance"))
        }
        XCTAssertEqual(fake.calls.count, count)

        // Missing CLI.
        do {
            _ = try await AWSCLI(executableURL: nil).json("sts", "get-caller-identity", settings: settings)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? AWSCLIError, .notInstalled)
        }
    }

    func testRunnerTimeoutAndCancel() async throws {
        let fake = try FakeAWS()
        defer { fake.remove() }
        try fake.set("sts", "get-caller-identity", json: "{}")
        try fake.sleep("sts", "get-caller-identity", seconds: 5)
        let started = Date()
        do {
            _ = try await AWSCLI(executableURL: fake.executable, timeout: 0.5).json("sts", "get-caller-identity", settings: nil)
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? AWSCLIError, .timedOut(0.5))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)

        let cli = AWSCLI(executableURL: fake.executable)
        let task = Task { try await cli.json("sts", "get-caller-identity", settings: nil) }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertEqual(error as? AWSCLIError, .cancelled)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 8)
    }

    func testLocate() throws {
        let fake = try FakeAWS()
        defer { fake.remove() }
        XCTAssertEqual(AWSCLI.locate(environment: ["TABLEEXTRA_AWS_CLI": fake.executable.path], candidates: [], useLoginShell: false)?.path,
                       fake.executable.path)
        XCTAssertNil(AWSCLI.locate(environment: ["TABLEEXTRA_AWS_CLI": "/nonexistent/aws"], candidates: [fake.executable.path], useLoginShell: false),
                     "a broken override is not silently replaced")
        XCTAssertEqual(AWSCLI.locate(environment: [:], candidates: ["/nonexistent/aws", fake.executable.path], useLoginShell: false)?.path,
                       fake.executable.path)
        XCTAssertNil(AWSCLI.locate(environment: [:], candidates: ["/nonexistent/aws"], useLoginShell: false))
    }

    // MARK: Model (fake script end to end)

    @MainActor
    func makeContext(host: String = "shop-prod.c9akciq32xyz.eu-west-3.rds.amazonaws.com", aws: AWSSettings? = nil) -> StandaloneWorkspaceContext {
        var config = ConnectionConfig(name: "shop prod", driver: .postgres, host: host, port: 5432, user: "app", database: "shop",
                                      sslMode: .require, environment: .production)
        config.aws = aws
        return StandaloneWorkspaceContext(connection: config, secrets: ConnectionSecrets())
    }

    @MainActor
    func testModelLoadsAndReports() async throws {
        let fake = try FakeAWS()
        defer { fake.remove() }
        try fake.installAll(cluster: false)
        // One section failing must not break the others.
        try fake.fail("rds", "describe-events", stderr: RDSFixtures.accessDeniedNoAction)
        let ctx = makeContext(aws: AWSSettings(profile: "prod-ro"))
        let settings = try XCTUnwrap(ctx.connection.effectiveAWS)
        XCTAssertEqual(settings.region, "eu-west-3")
        XCTAssertEqual(settings.identifier, "shop-prod")
        let model = RDSDashboardModel(context: ctx, settings: settings, runner: AWSCLI(executableURL: fake.executable))
        await model.refresh()
        XCTAssertNil(model.overview.error)
        XCTAssertEqual(model.overview.value?.writer?.identifier, "shop-prod")
        XCTAssertEqual(model.metrics.value?.count, 12)
        XCTAssertEqual(model.insights.value?.topSQL.count, 4)
        XCTAssertEqual(model.insights.value?.load.count, 360)
        XCTAssertNotNil(model.events.error)
        XCTAssertTrue(model.events.error?.contains("rds:DescribeEvents") ?? false, model.events.error ?? "")
        XCTAssertTrue(fake.calls.filter { $0.hasPrefix("ARGS") }.allSatisfy { $0.contains("<--profile> <prod-ro>") && $0.contains("<--region> <eu-west-3>") }, fake.calls.joined(separator: "\n"))

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
        let incomplete = RDSDashboardModel(context: ctx, settings: AWSSettings(profile: "p"), runner: StubRunner([:]))
        XCTAssertNil(incomplete.settings)
    }

    // MARK: Render (MTP_RENDER_DIR)

    @MainActor
    func testRenderRDSDashboard() async throws {
        guard let dir = ProcessInfo.processInfo.environment["MTP_RENDER_DIR"], !dir.isEmpty else { throw XCTSkip("MTP_RENDER_DIR not set") }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        for cluster in [false, true] {
            let fake = try FakeAWS()
            defer { fake.remove() }
            try fake.installAll(cluster: cluster)
            let ctx = cluster
                ? makeContext(host: "app-aurora.cluster-c1x2y3z4w5v6.eu-west-1.rds.amazonaws.com", aws: AWSSettings(profile: "app-ro"))
                : makeContext(aws: AWSSettings(profile: "prod-ro"))
            let model = RDSDashboardModel(context: ctx, settings: ctx.connection.effectiveAWS, runner: AWSCLI(executableURL: fake.executable))
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
        let model = RDSDashboardModel(context: makeContext(), settings: makeContext().connection.effectiveAWS, runner: StubRunner([:]))
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
