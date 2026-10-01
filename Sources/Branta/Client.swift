import Foundation

struct HTTPResult {
    var body: Data
    var statusCode: Int
}

protocol HTTPTransporting {
    func send(_ request: URLRequest) async throws -> HTTPResult
}

struct URLSessionTransport: HTTPTransporting {
    func send(_ request: URLRequest) async throws -> HTTPResult {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BrantaPaymentError(message: "Invalid response")
        }
        return HTTPResult(body: data, statusCode: http.statusCode)
    }
}

protocol BrantaClienting: AnyObject {
    func getPayments(destinationValue: String, options: BrantaClientOptions?) async throws -> [Payment]
    func postPayment(_ payment: Payment, options: BrantaClientOptions?) async throws -> Payment?
    func isAPIKeyValid(options: BrantaClientOptions?) async throws -> Bool
}

final class BrantaClient: BrantaClienting {
    private let defaultOptions: BrantaClientOptions?
    private let transport: HTTPTransporting
    var timestamp: () -> String = { String(Int(Date().timeIntervalSince1970)) }

    init(defaultOptions: BrantaClientOptions? = nil, transport: HTTPTransporting = URLSessionTransport()) {
        self.defaultOptions = defaultOptions
        self.transport = transport
    }

    func getPayments(destinationValue: String, options: BrantaClientOptions?) async throws -> [Payment] {
        let baseURL = try resolvedBaseURL(defaults: defaultOptions, override: options)
        let encoded = javaURLEncode(destinationValue)
        var request = URLRequest(url: URL(string: "\(baseURL)/v2/payments/\(encoded)")!)
        request.httpMethod = "GET"
        let response = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else { return [] }
        guard let payments = try decodePayments(response.body) else { return [] }
        try verifyLogoURLs(baseURL: baseURL, payments: payments)
        return payments
    }

    func postPayment(_ payment: Payment, options: BrantaClientOptions?) async throws -> Payment? {
        let baseURL = try resolvedBaseURL(defaults: defaultOptions, override: options)
        guard let apiKey = resolvedAPIKey(defaults: defaultOptions, override: options) else {
            throw BrantaPaymentError(message: "Unauthorized")
        }
        let body = try WireCoding.encode(payment)
        let bodyText = String(data: body, encoding: .utf8) ?? ""
        let url = "\(baseURL)/v2/payments"
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        if let hmacSecret = resolvedHMACSecret(defaults: defaultOptions, override: options) {
            let stamp = timestamp()
            let message = "POST|\(url)|\(bodyText)|\(stamp)"
            request.setValue(hmacSHA256Hex(secret: hmacSecret, message: message), forHTTPHeaderField: "X-HMAC-Signature")
            request.setValue(stamp, forHTTPHeaderField: "X-HMAC-Timestamp")
        }

        let response = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw BrantaPaymentError(message: String(response.statusCode))
        }
        return try decodePayment(response.body)
    }

    func isAPIKeyValid(options: BrantaClientOptions?) async throws -> Bool {
        let baseURL = try resolvedBaseURL(defaults: defaultOptions, override: options)
        guard let apiKey = resolvedAPIKey(defaults: defaultOptions, override: options) else {
            throw BrantaPaymentError(message: "Unauthorized")
        }
        var request = URLRequest(url: URL(string: "\(baseURL)/v2/api-keys/health-check")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let response = try await transport.send(request)
        return (200..<300).contains(response.statusCode)
    }

    private func decodePayments(_ data: Data) throws -> [Payment]? {
        if isEmptyBody(data) { return nil }
        return try WireCoding.decodePayments(data)
    }

    private func decodePayment(_ data: Data) throws -> Payment? {
        if isEmptyBody(data) { return nil }
        return try WireCoding.decodePayment(data)
    }

    private func isEmptyBody(_ data: Data) -> Bool {
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty || text == "null"
    }

    private func verifyLogoURLs(baseURL: String, payments: [Payment]) throws {
        guard let baseOrigin = origin(of: baseURL) else {
            throw BrantaPaymentError(message: "baseUrl domain does not match the configured baseUrl domain")
        }
        func check(_ logoURL: String?, _ fieldName: String) throws {
            guard let logoURL, !logoURL.isEmpty else { return }
            guard let logoOrigin = origin(of: logoURL), logoOrigin == baseOrigin else {
                throw BrantaPaymentError(message: "\(fieldName) domain does not match the configured baseUrl domain")
            }
        }
        for payment in payments {
            try check(payment.platformLogoURL, "platformLogoUrl")
            try check(payment.platformLogoLightURL, "platformLogoLightUrl")
            try check(payment.parentPlatform?.logoURL, "parentPlatform.logoUrl")
            try check(payment.parentPlatform?.logoLightURL, "parentPlatform.logoLightUrl")
            try check(payment.childPlatform?.logoURL, "childPlatform.logoUrl")
            try check(payment.childPlatform?.logoLightURL, "childPlatform.logoLightUrl")
        }
    }
}
