import AWSCloudWatch
import AWSPI
import AWSRDS
import AWSSDKIdentity
import AWSSTS
import Foundation
import MTPCore
import Smithy
import SmithyIdentity

/// Every AWS call TableExtra makes: describe / get operations only, so nothing here can change an AWS resource.
/// `AWSSDKRDSAPI` is the real implementation; tests use a stub that records the inputs.
public protocol AWSRDSAPI: Sendable {
    func describeDBInstances(_ input: DescribeDBInstancesInput) async throws -> DescribeDBInstancesOutput
    func describeDBClusters(_ input: DescribeDBClustersInput) async throws -> DescribeDBClustersOutput
    func describePendingMaintenanceActions(_ input: DescribePendingMaintenanceActionsInput) async throws -> DescribePendingMaintenanceActionsOutput
    func describeEvents(_ input: DescribeEventsInput) async throws -> DescribeEventsOutput
    func getMetricData(_ input: GetMetricDataInput) async throws -> GetMetricDataOutput
    func describeDimensionKeys(_ input: DescribeDimensionKeysInput) async throws -> DescribeDimensionKeysOutput
    func getResourceMetrics(_ input: GetResourceMetricsInput) async throws -> GetResourceMetricsOutput
    /// "arn:aws:sts::123456789012:assumed-role/ReadOnly/jane (account 123456789012)": proves the profile works.
    func callerIdentity() async throws -> String
}

/// AWS SDK for Swift clients for one connection's profile and region. Credentials come from the AWS folder the user
/// granted (`AWSConfigFolder`); nothing is read from ~/.aws before that, and no keys are stored by TableExtra.
public final class AWSSDKRDSAPI: AWSRDSAPI, @unchecked Sendable {
    public let profile: String
    public let region: String
    private let rds: RDSClient
    private let cloudWatch: CloudWatchClient
    private let pi: PIClient
    private let sts: STSClient

    public init(settings: AWSSettings, folder: URL? = AWSConfigFolder.url()) throws {
        guard let folder else { throw AWSError.noConfigAccess }
        guard let region = settings.region, !region.isEmpty else { throw AWSError.missingRegion }
        let profile = settings.profile.flatMap { $0.isEmpty ? nil : $0 } ?? "default"
        self.profile = profile
        self.region = region
        let resolver = ExpiringCredentialCache(source: try ProfileAWSCredentialIdentityResolver(
            profileName: profile,
            configFilePath: folder.appendingPathComponent("config").path,
            credentialsFilePath: folder.appendingPathComponent("credentials").path))
        rds = RDSClient(config: try RDSClient.RDSClientConfiguration(awsCredentialIdentityResolver: resolver, region: region))
        cloudWatch = CloudWatchClient(config: try CloudWatchClient.CloudWatchClientConfiguration(awsCredentialIdentityResolver: resolver, region: region))
        pi = PIClient(config: try PIClient.PIClientConfiguration(awsCredentialIdentityResolver: resolver, region: region))
        sts = STSClient(config: try STSClient.STSClientConfiguration(awsCredentialIdentityResolver: resolver, region: region))
    }

    /// Runs one call and maps its error; `permission` is the IAM action named when access is denied.
    private func call<T>(_ permission: String, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            throw AWSError.from(error, permission: permission, profile: profile)
        }
    }

    public func describeDBInstances(_ input: DescribeDBInstancesInput) async throws -> DescribeDBInstancesOutput {
        try await call("rds:DescribeDBInstances") { try await rds.describeDBInstances(input: input) }
    }

    public func describeDBClusters(_ input: DescribeDBClustersInput) async throws -> DescribeDBClustersOutput {
        try await call("rds:DescribeDBClusters") { try await rds.describeDBClusters(input: input) }
    }

    public func describePendingMaintenanceActions(_ input: DescribePendingMaintenanceActionsInput) async throws -> DescribePendingMaintenanceActionsOutput {
        try await call("rds:DescribePendingMaintenanceActions") { try await rds.describePendingMaintenanceActions(input: input) }
    }

    public func describeEvents(_ input: DescribeEventsInput) async throws -> DescribeEventsOutput {
        try await call("rds:DescribeEvents") { try await rds.describeEvents(input: input) }
    }

    public func getMetricData(_ input: GetMetricDataInput) async throws -> GetMetricDataOutput {
        try await call("cloudwatch:GetMetricData") { try await cloudWatch.getMetricData(input: input) }
    }

    public func describeDimensionKeys(_ input: DescribeDimensionKeysInput) async throws -> DescribeDimensionKeysOutput {
        try await call("pi:DescribeDimensionKeys") { try await pi.describeDimensionKeys(input: input) }
    }

    public func getResourceMetrics(_ input: GetResourceMetricsInput) async throws -> GetResourceMetricsOutput {
        try await call("pi:GetResourceMetrics") { try await pi.getResourceMetrics(input: input) }
    }

    public func callerIdentity() async throws -> String {
        let me = try await call("sts:GetCallerIdentity") { try await sts.getCallerIdentity(input: GetCallerIdentityInput()) }
        let arn = me.arn ?? "?"
        return me.account.map { "\(arn) (account \($0))" } ?? arn
    }
}

/// Keeps resolved credentials until five minutes before they expire, so an assumed role or SSO session is not
/// re-fetched for every call (the SDK's own cache only refreshes on a fixed interval).
actor ExpiringCredentialCache: AWSCredentialIdentityResolver {
    private let source: any AWSCredentialIdentityResolver
    private var cached: AWSCredentialIdentity?
    private var fetchedAt: Date?

    init(source: any AWSCredentialIdentityResolver) {
        self.source = source
    }

    func getIdentity(identityProperties: Attributes?) async throws -> AWSCredentialIdentity {
        if let cached, let fetchedAt {
            let validUntil = cached.expiration.map { $0.addingTimeInterval(-300) } ?? fetchedAt.addingTimeInterval(900)
            if Date() < validUntil { return cached }
        }
        let fresh = try await source.getIdentity(identityProperties: identityProperties)
        cached = fresh
        fetchedAt = Date()
        return fresh
    }
}
