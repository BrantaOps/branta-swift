import Foundation

public enum BrantaEnvironment: String, Sendable, Equatable {
    case staging = "https://staging.guardrail.branta.pro"
    case production = "https://guardrail.branta.pro"
    case localhost = "http://localhost:3000"

    public var url: String { rawValue }
}

/// Service configuration, overridable per call.
/// A nil `environment` means unset and uses staging. An empty per-call `apiKey` or `hmacSecret` does not override.
public struct BrantaApiOptions: Sendable, Equatable {
    public var environment: BrantaEnvironment?
    public var apiKey: String?
    /// Deprecated parent-platform HMAC. Prefer a shared `apiKey` plus `PaymentBuilder.setChildPlatform`.
    @available(*, deprecated, message: "Use a shared apiKey with PaymentBuilder.setChildPlatform instead.")
    public var hmacSecret: String? {
        get { _hmacSecret }
        set { _hmacSecret = newValue }
    }

    var _hmacSecret: String?

    public init(environment: BrantaEnvironment? = nil, apiKey: String? = nil) {
        self.environment = environment
        self.apiKey = apiKey
        self._hmacSecret = nil
    }

    @available(*, deprecated, message: "Use a shared apiKey with PaymentBuilder.setChildPlatform instead.")
    public init(
        environment: BrantaEnvironment? = nil,
        apiKey: String? = nil,
        hmacSecret: String?
    ) {
        self.environment = environment
        self.apiKey = apiKey
        self._hmacSecret = hmacSecret
    }
}

public struct BrantaPaymentError: Error, Equatable, CustomStringConvertible, LocalizedError {
    public let message: String

    public init(message: String) {
        self.message = message
    }

    public var description: String { message }
    public var errorDescription: String? { message }
}

enum LookupFailure: Error, Equatable {
    case tampered
    case incomplete
}

func resolvedBaseURL(defaults: BrantaApiOptions?, override: BrantaApiOptions?) -> String {
    if let environment = override?.environment {
        return environment.url
    }
    if let environment = defaults?.environment {
        return environment.url
    }
    return BrantaEnvironment.staging.url
}

func resolvedAPIKey(defaults: BrantaApiOptions?, override: BrantaApiOptions?) -> String? {
    if let key = override?.apiKey, !key.isEmpty { return key }
    if let key = defaults?.apiKey, !key.isEmpty { return key }
    return nil
}

func resolvedHMACSecret(defaults: BrantaApiOptions?, override: BrantaApiOptions?) -> String? {
    if let secret = override?._hmacSecret, !secret.isEmpty { return secret }
    if let secret = defaults?._hmacSecret, !secret.isEmpty { return secret }
    return nil
}
