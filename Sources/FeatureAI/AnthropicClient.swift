import Foundation
import MTPAgentTools

public enum AnthropicAPIError: LocalizedError, Equatable {
    case noKey
    case unauthorized(String)
    case rateLimited(String)
    case overloaded(String)
    case http(status: Int, type: String, message: String)
    case refusal(category: String?)
    case network(String)
    case invalidResponse(String)
    case tooManySteps(Int)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .noKey:
            return "No Anthropic API key. Add one in Settings → AI (create it at console.anthropic.com)."
        case .unauthorized(let m):
            return "The Anthropic API key was rejected (\(m)). Check it in Settings → AI."
        case .rateLimited(let m):
            return "Rate limited by the Claude API: \(m)"
        case .overloaded(let m):
            return "The Claude API is overloaded, try again in a moment (\(m))."
        case .http(let status, let type, let m):
            return "Claude API error \(status) (\(type)): \(m)"
        case .refusal(let category):
            return "Claude declined this request" + (category.map { " (\($0))" } ?? "") + ". Rephrase it or try another model."
        case .network(let m):
            return "Cannot reach the Claude API: \(m)"
        case .invalidResponse(let m):
            return "Unexpected answer from the Claude API: \(m.prefix(300))"
        case .tooManySteps(let n):
            return "Claude used its \(n) tool calls without finishing. Ask a narrower question."
        case .cancelled:
            return "Cancelled."
        }
    }
}

/// Raw HTTP client for `POST /v1/messages` (there is no official Swift SDK). Bodies and responses are JSONValue, so
/// assistant content blocks (thinking, tool_use, fallback) are echoed back exactly as received.
public struct AnthropicClient: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public static let apiVersion = "2026-10-21"
    public static let defaultBaseURL = URL(string: "https://api.anthropic.com")!

    public var apiKey: String
    public var baseURL: URL
    public var maxRetries: Int
    var transport: Transport
    /// Backoff before retry `n` (0-based); tests make it instant.
    var delay: @Sendable (Int, TimeInterval?) async throws -> Void

    public init(apiKey: String, baseURL: URL = AnthropicClient.defaultBaseURL, maxRetries: Int = 2,
                transport: Transport? = nil) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.maxRetries = maxRetries
        self.transport = transport ?? { request in try await URLSession.shared.data(for: request) }
        self.delay = { attempt, retryAfter in
            let seconds = min(retryAfter ?? pow(2, Double(attempt)) * 1.5, 30)
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    }

    /// The key from the Keychain.
    public static func fromKeychain() throws -> AnthropicClient {
        guard let key = AnthropicAPIKey.value, !key.isEmpty else { throw AnthropicAPIError.noKey }
        return AnthropicClient(apiKey: key)
    }

    func request(_ body: JSONValue, betas: [String]) throws -> URLRequest {
        var r = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
        r.httpMethod = "POST"
        r.timeoutInterval = 600
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        r.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        r.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        if !betas.isEmpty { r.setValue(betas.joined(separator: ","), forHTTPHeaderField: "anthropic-beta") }
        r.httpBody = Data(body.serialized().utf8)
        return r
    }

    /// One Messages call. Retries 429, 5xx and connection failures (`maxRetries` times, honouring retry-after).
    public func createMessage(_ body: JSONValue, betas: [String] = []) async throws -> JSONValue {
        let request = try request(body, betas: betas)
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let data: Data
            let http: HTTPURLResponse
            do {
                let (d, response) = try await transport(request)
                guard let h = response as? HTTPURLResponse else { throw AnthropicAPIError.invalidResponse("not an HTTP response") }
                data = d
                http = h
            } catch is CancellationError {
                throw AnthropicAPIError.cancelled
            } catch let e as URLError where e.code == .cancelled {
                throw AnthropicAPIError.cancelled
            } catch let e as AnthropicAPIError {
                throw e
            } catch {
                if attempt < maxRetries {
                    try await delay(attempt, nil)
                    attempt += 1
                    continue
                }
                throw AnthropicAPIError.network(error.localizedDescription)
            }
            if (200..<300).contains(http.statusCode) {
                guard let json = try? JSONDecoder().decode(JSONValue.self, from: data) else {
                    throw AnthropicAPIError.invalidResponse(String(decoding: data.prefix(300), as: UTF8.self))
                }
                return json
            }
            let error = Self.error(status: http.statusCode, data: data)
            let retryable = http.statusCode == 429 || http.statusCode >= 500
            if retryable, attempt < maxRetries {
                let retryAfter = http.value(forHTTPHeaderField: "retry-after").flatMap(Double.init)
                try await delay(attempt, retryAfter)
                attempt += 1
                continue
            }
            throw error
        }
    }

    static func error(status: Int, data: Data) -> AnthropicAPIError {
        let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        let type = json?["error"]?["type"]?.stringValue ?? "error"
        let message = json?["error"]?["message"]?.stringValue ?? String(decoding: data.prefix(300), as: UTF8.self)
        switch status {
        case 401: return .unauthorized(message)
        case 403 where type == "permission_error": return .unauthorized(message)
        case 429: return .rateLimited(message)
        case 529: return .overloaded(message)
        default: return .http(status: status, type: type, message: message)
        }
    }
}
