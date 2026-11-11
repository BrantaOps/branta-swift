import CryptoKit
import Foundation

public enum BrantaEnvironment: String, Sendable, Equatable {
    case staging = "https://staging.guardrail.branta.pro"
    case production = "https://guardrail.branta.pro"
    case localhost = "http://localhost:3000"

    public var url: String { rawValue }
}

/// A destination `addPayment` can encrypt.
public enum DestinationType: String, Sendable, Equatable, Codable {
    case bitcoinAddress = "bitcoin_address"
    case bolt11 = "bolt11"
    case arkAddress = "ark_address"
    case silentPayment = "silent_payment"
    case usdtPolygon = "usdt_polygon"
    case usdcPolygon = "usdc_polygon"
}

/// Polygon EVM secret-key rails. A `pol:` URI maps to this family for verify
/// (match-if-any). Token is still the destination type on the payment.
public let polygonEvmDestinationTypes: [DestinationType] = [.usdtPolygon, .usdcPolygon]

public func isPolygonEvmDestinationType(_ type: DestinationType) -> Bool {
    type == .usdtPolygon || type == .usdcPolygon
}

/// Address rails encrypted with a random `branta_secret` (not a derived key).
public func isSecretKeyAddressType(_ type: DestinationType) -> Bool {
    type == .bitcoinAddress || isPolygonEvmDestinationType(type)
}

public enum VerifyStatus: String, Sendable, Equatable {
    case match
    case unknown
    case tampered
    case incomplete
}

/// Service configuration, overridable per call.
/// A nil `environment` means unset and uses staging. An empty per-call `apiKey` or `hmacSecret` does not override.
public struct BrantaApiOptions: Sendable, Equatable {
    public var environment: BrantaEnvironment?
    public var apiKey: String?
    public var hmacSecret: String?

    public init(
        environment: BrantaEnvironment? = nil,
        apiKey: String? = nil,
        hmacSecret: String? = nil
    ) {
        self.environment = environment
        self.apiKey = apiKey
        self.hmacSecret = hmacSecret
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
    if let secret = override?.hmacSecret, !secret.isEmpty { return secret }
    if let secret = defaults?.hmacSecret, !secret.isEmpty { return secret }
    return nil
}

func isBolt11(_ value: String) -> Bool {
    let lower = value.lowercased()
    return lower.hasPrefix("lnbc") || lower.hasPrefix("lntb") || lower.hasPrefix("lnbcrt")
}

func isArk(_ value: String) -> Bool {
    let lower = value.lowercased()
    return lower.hasPrefix("ark1") || lower.hasPrefix("tark1")
}

func isSilentPayment(_ value: String) -> Bool {
    let lower = value.lowercased()
    return lower.hasPrefix("sp1") || lower.hasPrefix("tsp1")
}

func derivedKeyType(of value: String) -> DestinationType? {
    if isBolt11(value) { return .bolt11 }
    if isArk(value) { return .arkAddress }
    if isSilentPayment(value) { return .silentPayment }
    return nil
}

func normalizedHash(_ value: String) -> String {
    let digest = SHA256.hash(data: Data(value.lowercased().utf8))
    return digest.map { String(format: "%02X", $0) }.joined()
}

func urlFragment(for keys: [(String, String)]) -> String {
    if keys.isEmpty { return "" }
    return "#" + keys.map { "k-\(fragmentEscape($0.0))=\(fragmentEscape($0.1))" }.joined(separator: "&")
}

func addressesMatch(_ a: String, _ b: String) -> Bool {
    func isBech32(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.hasPrefix("bc1") || lower.hasPrefix("tb1") || lower.hasPrefix("bcrt1")
    }
    if isBech32(a) && isBech32(b) {
        return a.lowercased() == b.lowercased()
    }
    if a.lowercased().hasPrefix("0x") && b.lowercased().hasPrefix("0x") {
        return a.lowercased() == b.lowercased()
    }
    return a == b
}

/// Percent-encodes everything except unreserved characters, matching .NET `Uri.EscapeDataString`.
/// This encodes `+`, `/`, and `=`, which appear in base64 ciphertext lookup values.
func pathEscape(_ value: String) -> String {
    percentEncode(value, safe: isPathUnreserved)
}

/// Percent-encodes with the `encodeURIComponent` set: everything except
/// ALPHA / DIGIT / "-" / "_" / "." / "!" / "~" / "*" / "'" / "(" / ")".
func fragmentEscape(_ value: String) -> String {
    percentEncode(value, safe: isFragmentSafe)
}

func pathUnescape(_ value: String) -> String {
    var out: [UInt8] = []
    let bytes = Array(value.utf8)
    var index = 0
    while index < bytes.count {
        if bytes[index] == UInt8(ascii: "%") {
            if index + 2 >= bytes.count { return value }
            let hex = String(bytes: [bytes[index + 1], bytes[index + 2]], encoding: .ascii) ?? ""
            guard let byte = UInt8(hex, radix: 16) else { return value }
            out.append(byte)
            index += 3
        } else {
            out.append(bytes[index])
            index += 1
        }
    }
    return String(bytes: out, encoding: .utf8) ?? value
}

func hmacSHA256Hex(secret: String, message: String) -> String {
    let key = SymmetricKey(data: Data(secret.utf8))
    let code = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
    return code.map { String(format: "%02x", $0) }.joined()
}

func origin(of urlString: String) -> String? {
    guard let components = URLComponents(string: urlString),
          let scheme = components.scheme,
          let host = components.host,
          !scheme.isEmpty, !host.isEmpty else {
        return nil
    }
    if let port = components.port {
        return "\(scheme)://\(host):\(port)".lowercased()
    }
    return "\(scheme)://\(host)".lowercased()
}

private func percentEncode(_ value: String, safe: (UInt8) -> Bool) -> String {
    var out = ""
    for byte in value.utf8 {
        if safe(byte) {
            out.append(Character(UnicodeScalar(byte)))
        } else {
            out.append(String(format: "%%%02X", byte))
        }
    }
    return out
}

private func isPathUnreserved(_ byte: UInt8) -> Bool {
    if isASCIIAlphanumeric(byte) { return true }
    switch byte {
    case UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "~"):
        return true
    default:
        return false
    }
}

private func isFragmentSafe(_ byte: UInt8) -> Bool {
    if isASCIIAlphanumeric(byte) { return true }
    switch byte {
    case UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."),
         UInt8(ascii: "!"), UInt8(ascii: "~"), UInt8(ascii: "*"),
         UInt8(ascii: "'"), UInt8(ascii: "("), UInt8(ascii: ")"):
        return true
    default:
        return false
    }
}

func isASCIIAlpha(_ byte: UInt8) -> Bool {
    (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
        || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
}

func isASCIIAlphanumeric(_ byte: UInt8) -> Bool {
    isASCIIAlpha(byte) || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
}
