import AWSClientRuntime
import AWSSDKIdentity
import Foundation

public enum AWSError: Error, LocalizedError, Equatable {
    /// The user has not granted access to their AWS folder yet (see `AWSConfigFolder.requestAccess()`).
    case noConfigAccess
    case ssoExpired(profile: String?)
    case expiredCredentials(profile: String?)
    case noCredentials(profile: String?)
    case unknownProfile(String)
    /// `permission` is the IAM action to grant (rds:DescribeDBInstances…).
    case accessDenied(permission: String, message: String)
    case notFound(String)
    case missingRegion
    case network(String)
    case cancelled
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .noConfigAccess:
            return "TableExtra needs your permission to read your AWS folder (~/.aws) for profiles and credentials. "
                + "Use “Allow Access to ~/.aws…” in the connection settings."
        case .ssoExpired(let profile):
            return "The AWS SSO session has expired. Run `aws sso login\(Self.profileFlag(profile))` in Terminal, then refresh."
        case .expiredCredentials(let profile):
            return "The AWS credentials have expired. Renew them (for SSO: `aws sso login\(Self.profileFlag(profile))`), then refresh."
        case .noCredentials(let profile):
            return "No AWS credentials found\(profile.map { " for profile \($0)" } ?? ""). Add them to ~/.aws "
                + "(`aws configure sso` or `aws configure`), or pick another profile in the connection settings."
        case .unknownProfile(let profile):
            return "The AWS profile \"\(profile)\" does not exist in the AWS folder TableExtra can read. Pick another one in the connection settings."
        case .accessDenied(let permission, _):
            return "Access denied: the IAM identity needs the \(permission) permission (read-only)."
        case .notFound(let message):
            return "Not found: \(message). Check the DB identifier and region in the connection settings."
        case .missingRegion:
            return "No AWS region set. Set it in the connection settings (AWS section)."
        case .network(let message):
            return "Cannot reach AWS: \(message)"
        case .cancelled:
            return "Cancelled."
        case .failed(let message):
            return message
        }
    }

    static func profileFlag(_ profile: String?) -> String {
        guard let profile, !profile.isEmpty else { return "" }
        return " --profile \(profile)"
    }

    /// Turns an AWS SDK error into an actionable one. `permission` is the IAM action of the call that failed.
    public static func from(_ error: Error, permission: String, profile: String?) -> AWSError {
        if let e = error as? AWSError { return e }
        if error is CancellationError { return .cancelled }
        let profile = profile?.isEmpty == false ? profile : nil
        if let service = error as? AWSServiceError {
            return from(code: service.typeName ?? "", message: service.message ?? "", permission: permission, profile: profile)
        }
        if case .failedToResolveAWSCredentials(let message) = error as? AWSCredentialIdentityResolverError {
            return credentials(message, profile: profile)
        }
        if let url = error as? URLError {
            return url.code == .cancelled ? .cancelled : .network(url.localizedDescription)
        }
        let text = String(describing: error)
        let lower = text.lowercased()
        if lower.contains("profile") && (lower.contains("not found") || lower.contains("doesn't exist")) || lower.contains("credential") {
            return credentials(text, profile: profile)
        }
        if lower.contains("timed out") || lower.contains("network") || lower.contains("host") && lower.contains("resolve") || lower.contains("socket") {
            return .network(text)
        }
        return .failed(text)
    }

    /// Error code + message from an AWS service response.
    static func from(code: String, message: String, permission: String, profile: String?) -> AWSError {
        let lowerCode = code.lowercased()
        let lower = message.lowercased()
        if lowerCode.contains("expiredtoken") || lower.contains("security token included in the request is expired") || lowerCode == "requestexpired" {
            return .expiredCredentials(profile: profile)
        }
        if lowerCode.contains("accessdenied") || lowerCode.contains("notauthorized") || lowerCode == "unauthorizedoperation"
            || lower.contains("is not authorized to perform") {
            let action = message.range(of: #"not authorized to perform: [A-Za-z0-9-]+:[A-Za-z0-9]+"#, options: .regularExpression)
                .map { String(message[$0].dropFirst("not authorized to perform: ".count)) }
            return .accessDenied(permission: action ?? permission, message: message)
        }
        if lowerCode == "invalidclienttokenid" || lowerCode == "unrecognizedclientexception" || lowerCode == "signaturedoesnotmatch" {
            return .noCredentials(profile: profile)
        }
        if lowerCode.contains("notfound") || lower.contains("not found") {
            return .notFound(message.isEmpty ? code : message)
        }
        return .failed(message.isEmpty ? code : "\(message) (\(code))")
    }

    static func credentials(_ message: String, profile: String?) -> AWSError {
        let lower = message.lowercased()
        if lower.contains("sso") && (lower.contains("expired") || lower.contains("token") || lower.contains("login")) {
            return .ssoExpired(profile: profile)
        }
        if lower.contains("doesn't exist") || lower.contains("not found") && lower.contains("profile") {
            return .unknownProfile(profile ?? "default")
        }
        if lower.contains("expired") { return .expiredCredentials(profile: profile) }
        return .noCredentials(profile: profile)
    }
}
