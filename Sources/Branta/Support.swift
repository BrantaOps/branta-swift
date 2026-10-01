import CryptoKit
import Foundation

public enum BrantaServerBaseURL: String, Sendable, Equatable {
    case staging = "https://staging.guardrail.branta.pro"
    case production = "https://guardrail.branta.pro"
    case localhost = "http://localhost:3000"

    public var url: String { rawValue }
}

public enum PrivacyMode: Sendable, Equatable {
    case strict
    case loose
}

public enum DestinationType: String, Sendable, Equatable, Codable {
    case bitcoinAddress = "bitcoin_address"
    case bolt11 = "bolt11"
    case bolt12 = "bolt12"
    case lnURL = "ln_url"
    case tetherAddress = "tether_address"
    case lnAddress = "ln_address"
    case arkAddress = "ark_address"
    case silentPayment = "silent_payment"

    /// Kotlin's enum name, used in the unsupported-ZK error so the message matches the other SDKs.
    var kotlinName: String {
        switch self {
        case .bitcoinAddress: return "BitcoinAddress"
        case .bolt11: return "Bolt11"
        case .bolt12: return "Bolt12"
        case .lnURL: return "LnUrl"
        case .tetherAddress: return "TetherAddress"
        case .lnAddress: return "LnAddress"
        case .arkAddress: return "ArkAddress"
        case .silentPayment: return "SilentPayment"
        }
    }
}

public struct BrantaClientOptions: Sendable, Equatable {
    public var baseURL: BrantaServerBaseURL?
    public var defaultAPIKey: String?
    public var hmacSecret: String?
    public var privacy: PrivacyMode?

    public init(
        baseURL: BrantaServerBaseURL? = nil,
        defaultAPIKey: String? = nil,
        hmacSecret: String? = nil,
        privacy: PrivacyMode? = nil
    ) {
        self.baseURL = baseURL
        self.defaultAPIKey = defaultAPIKey
        self.hmacSecret = hmacSecret
        self.privacy = privacy
    }
}

public struct BrantaPaymentError: Error, Equatable, CustomStringConvertible, LocalizedError {
    public enum Reason: Equatable, Sendable {
        case tampered
    }

    public let message: String
    public let reason: Reason?

    public init(message: String, reason: Reason? = nil) {
        self.message = message
        self.reason = reason
    }

    public var description: String { message }
    public var errorDescription: String? { message }
}

func resolvedBaseURL(defaults: BrantaClientOptions?, override: BrantaClientOptions?) throws -> String {
    if let url = override?.baseURL?.url ?? defaults?.baseURL?.url {
        return url
    }
    throw BrantaPaymentError(message: "Branta: baseUrl is a required option.")
}

func resolvedPrivacy(defaults: BrantaClientOptions?, override: BrantaClientOptions?) -> PrivacyMode {
    override?.privacy ?? defaults?.privacy ?? .strict
}

func resolvedAPIKey(defaults: BrantaClientOptions?, override: BrantaClientOptions?) -> String? {
    override?.defaultAPIKey ?? defaults?.defaultAPIKey
}

func resolvedHMACSecret(defaults: BrantaClientOptions?, override: BrantaClientOptions?) -> String? {
    override?.hmacSecret ?? defaults?.hmacSecret
}

func isBolt11(_ value: String) -> Bool {
    let lower = value.lowercased()
    return lower.hasPrefix("lnbc") || lower.hasPrefix("lntb") || lower.hasPrefix("lnbcrt")
}

func isArk(_ value: String) -> Bool {
    value.lowercased().hasPrefix("ark1")
}

func isSilentPayment(_ value: String) -> Bool {
    let lower = value.lowercased()
    return lower.hasPrefix("sp1") || lower.hasPrefix("tsp1")
}

func hashZKType(of value: String) -> DestinationType? {
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
    "#" + keys.map { "k-\($0.0)=\($0.1)" }.joined(separator: "&")
}

func addressesMatch(_ a: String, _ b: String) -> Bool {
    func isBech32(_ value: String) -> Bool { value.lowercased().hasPrefix("bc1") }
    if isBech32(a) && isBech32(b) {
        return a.lowercased() == b.lowercased()
    }
    return a == b
}

/// Java `URLEncoder.encode` / `URLDecoder.decode` (UTF-8). The other SDKs use this for payment paths and verify URLs.
func javaURLEncode(_ value: String) -> String {
    var out = ""
    for byte in value.utf8 {
        let allowed = (byte >= 0x30 && byte <= 0x39)
            || (byte >= 0x41 && byte <= 0x5A)
            || (byte >= 0x61 && byte <= 0x7A)
            || byte == 0x2D || byte == 0x5F || byte == 0x2E || byte == 0x2A
        if byte == 0x20 {
            out.append("+")
        } else if allowed {
            out.append(Character(UnicodeScalar(byte)))
        } else {
            out.append(String(format: "%%%02X", byte))
        }
    }
    return out
}

func javaURLDecode(_ value: String) -> String {
    let replaced = value.replacingOccurrences(of: "+", with: " ")
    var bytes: [UInt8] = []
    var index = replaced.startIndex
    while index < replaced.endIndex {
        if replaced[index] == "%",
           let first = replaced.index(index, offsetBy: 1, limitedBy: replaced.endIndex),
           let second = replaced.index(index, offsetBy: 2, limitedBy: replaced.endIndex),
           second < replaced.endIndex,
           let byte = UInt8(replaced[first...second], radix: 16) {
            bytes.append(byte)
            index = replaced.index(after: second)
        } else {
            bytes.append(contentsOf: String(replaced[index]).utf8)
            index = replaced.index(after: index)
        }
    }
    return String(bytes: bytes, encoding: .utf8) ?? replaced
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
        return "\(scheme)://\(host):\(port)"
    }
    return "\(scheme)://\(host)"
}
