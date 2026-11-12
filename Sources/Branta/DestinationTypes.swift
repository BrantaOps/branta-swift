import Foundation

/// A destination `addPayment` can encrypt.
public enum DestinationType: String, Sendable, Equatable, Codable {
    case bitcoinAddress = "bitcoin_address"
    case bolt11 = "bolt11"
    case arkAddress = "ark_address"
    case silentPayment = "silent_payment"
    case usdtPolygon = "usdt_polygon"
    case usdcPolygon = "usdc_polygon"
    case usdtEthereum = "usdt_ethereum"
    case usdcEthereum = "usdc_ethereum"
    case usdtBsc = "usdt_bsc"
    case usdcBsc = "usdc_bsc"
    case usdtTron = "usdt_tron"
    case usdtTon = "usdt_ton"
    case usdtSolana = "usdt_solana"
    case usdcSolana = "usdc_solana"
}

/// Polygon EVM secret-key rails. A `pol:` URI maps to this family for verify
/// (match-if-any). Token is still the destination type on the payment.
let polygonEvmDestinationTypes: [DestinationType] = [.usdtPolygon, .usdcPolygon]
let ethereumEvmDestinationTypes: [DestinationType] = [.usdtEthereum, .usdcEthereum]
let bscEvmDestinationTypes: [DestinationType] = [.usdtBsc, .usdcBsc]
let tronDestinationTypes: [DestinationType] = [.usdtTron]
let tonDestinationTypes: [DestinationType] = [.usdtTon]
let solanaDestinationTypes: [DestinationType] = [.usdtSolana, .usdcSolana]

/// URI scheme -> secret-key destination family for verify (match-if-any).
let secretKeyURIFamilies: [String: [DestinationType]] = [
    "pol": polygonEvmDestinationTypes,
    "eth": ethereumEvmDestinationTypes,
    "bsc": bscEvmDestinationTypes,
    "tron": tronDestinationTypes,
    "ton": tonDestinationTypes,
    "sol": solanaDestinationTypes,
]

/// Address rails encrypted with a random `branta_secret` (not a derived key).
func isSecretKeyAddressType(_ type: DestinationType) -> Bool {
    type == .bitcoinAddress || secretKeyURIFamilies.values.contains { $0.contains(type) }
}

public enum VerifyStatus: String, Sendable, Equatable {
    case match
    case unknown
    case tampered
    case incomplete
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
