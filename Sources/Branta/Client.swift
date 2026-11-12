import Foundation

struct HTTPResult {
    var body: Data
    var statusCode: Int
}

protocol HTTPTransporting {
    func send(_ request: URLRequest) async throws -> HTTPResult
}

/// `URLSession` transport with a finite request/resource timeout so hung networks
/// surface as transport errors (mapped to `incomplete` on GET).
struct URLSessionTransport: HTTPTransporting {
    let session: URLSession
    let timeout: TimeInterval

    init(timeout: TimeInterval = 30) {
        self.timeout = timeout
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        self.session = URLSession(configuration: config)
    }

    func send(_ request: URLRequest) async throws -> HTTPResult {
        var request = request
        request.timeoutInterval = timeout
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BrantaPaymentError(message: "Invalid response")
        }
        return HTTPResult(body: data, statusCode: http.statusCode)
    }
}

protocol BrantaClienting: AnyObject {
    func getPayments(destinationValue: String, options: BrantaApiOptions?) async throws -> [Payment]
    func postPayment(_ payment: Payment, options: BrantaApiOptions?) async throws -> Payment?
    func isAPIKeyValid(options: BrantaApiOptions?) async throws -> Bool
}

final class BrantaClient: BrantaClienting {
    private let defaultOptions: BrantaApiOptions?
    private let transport: HTTPTransporting
    var timestamp: () -> String = { String(Int(Date().timeIntervalSince1970)) }
    var integrationMetricsToken = ""

    init(defaultOptions: BrantaApiOptions? = nil, transport: HTTPTransporting = URLSessionTransport()) {
        self.defaultOptions = defaultOptions
        self.transport = transport
    }

    func getPayments(destinationValue: String, options: BrantaApiOptions?) async throws -> [Payment] {
        let baseURL = resolvedBaseURL(defaults: defaultOptions, override: options)
        let encoded = pathEscape(destinationValue)
        guard let url = URL(string: "\(baseURL)/v2/payments/\(encoded)") else {
            throw LookupFailure.incomplete
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if !integrationMetricsToken.isEmpty {
            request.setValue(integrationMetricsToken, forHTTPHeaderField: "X-Branta-Integration-Token")
        }
        let response: HTTPResult
        do {
            response = try await transport.send(request)
        } catch {
            throw LookupFailure.incomplete
        }
        if response.statusCode == 404 { return [] }
        guard (200..<300).contains(response.statusCode) else {
            throw LookupFailure.incomplete
        }
        let payments: [Payment]
        do {
            payments = try WireCoding.decodePayments(response.body)
        } catch {
            // Malformed JSON or a bad row shape — treat as unfinished lookup, not a crash.
            throw LookupFailure.incomplete
        }
        try verifyLogoURLs(baseURL: baseURL, payments: payments)
        return payments
    }

    func postPayment(_ payment: Payment, options: BrantaApiOptions?) async throws -> Payment? {
        let baseURL = resolvedBaseURL(defaults: defaultOptions, override: options)
        guard let apiKey = resolvedAPIKey(defaults: defaultOptions, override: options) else {
            throw BrantaPaymentError(message: "Unauthorized")
        }
        let body = try WireCoding.encode(payment)
        let bodyText = String(data: body, encoding: .utf8) ?? ""
        let urlString = "\(baseURL)/v2/payments"
        guard let url = URL(string: urlString) else {
            throw BrantaPaymentError(message: "Invalid response")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        if let hmacSecret = resolvedHMACSecret(defaults: defaultOptions, override: options) {
            let stamp = timestamp()
            let message = "POST|\(urlString)|\(bodyText)|\(stamp)"
            request.setValue(hmacSHA256Hex(secret: hmacSecret, message: message), forHTTPHeaderField: "X-HMAC-Signature")
            request.setValue(stamp, forHTTPHeaderField: "X-HMAC-Timestamp")
        }

        let response = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw BrantaPaymentError(message: "request failed with status \(response.statusCode)")
        }
        return try decodePayment(response.body)
    }

    func isAPIKeyValid(options: BrantaApiOptions?) async throws -> Bool {
        let baseURL = resolvedBaseURL(defaults: defaultOptions, override: options)
        guard let apiKey = resolvedAPIKey(defaults: defaultOptions, override: options) else {
            throw BrantaPaymentError(message: "Unauthorized")
        }
        guard let url = URL(string: "\(baseURL)/v2/api-keys/health-check") else {
            throw BrantaPaymentError(message: "Invalid response")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let response = try await transport.send(request)
        return (200..<300).contains(response.statusCode)
    }

    private func decodePayment(_ data: Data) throws -> Payment? {
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty || text == "null" { return nil }
        return try WireCoding.decodePayment(data)
    }

    private func verifyLogoURLs(baseURL: String, payments: [Payment]) throws {
        guard let baseOrigin = origin(of: baseURL) else { return }
        func check(_ logoURL: String?, _ fieldName: String) throws {
            guard let logoURL, !logoURL.isEmpty else { return }
            guard let logoOrigin = origin(of: logoURL), logoOrigin == baseOrigin else {
                throw BrantaPaymentError(message: "\(fieldName) domain does not match the configured environment")
            }
        }
        for payment in payments {
            try check(payment.platformLogoURL, "platformLogoURL")
            try check(payment.platformLogoLightURL, "platformLogoLightURL")
            try check(payment.parentPlatform?.logoURL, "parentPlatform.logoURL")
            try check(payment.parentPlatform?.logoLightURL, "parentPlatform.logoLightURL")
            try check(payment.childPlatform?.logoURL, "childPlatform.logoURL")
            try check(payment.childPlatform?.logoLightURL, "childPlatform.logoLightURL")
        }
    }
}
