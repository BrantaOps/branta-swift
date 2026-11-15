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
    case usdtBase = "usdt_base"
    case usdcBase = "usdc_base"
    case usdtArbitrum = "usdt_arbitrum"
    case usdcArbitrum = "usdc_arbitrum"
}

/// An ERC-681 `ethereum:<contract>@<chainId>/transfer` rail.
struct EVMTokenRail {
    let chainID: Int
    /// Lowercase, so lookup is case-insensitive.
    let contract: String
    let type: DestinationType
}

/// Chain id plus token contract select one destination type.
let evmTokenRails: [EVMTokenRail] = [
    EVMTokenRail(chainID: 1, contract: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48", type: .usdcEthereum),
    EVMTokenRail(chainID: 1, contract: "0xdac17f958d2ee523a2206206994597c13d831ec7", type: .usdtEthereum),
    EVMTokenRail(chainID: 137, contract: "0x3c499c542cef5e3811e1192ce70d8cc03d5c3359", type: .usdcPolygon),
    EVMTokenRail(chainID: 137, contract: "0xc2132d05d31c914a87c6611c10748aeb04b58e8f", type: .usdtPolygon),
    EVMTokenRail(chainID: 8453, contract: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913", type: .usdcBase),
    EVMTokenRail(chainID: 8453, contract: "0xfde4c96c8593536e31f229ea8f37b2ada2699bb2", type: .usdtBase),
    EVMTokenRail(chainID: 42161, contract: "0xaf88d065e77c8cc2239327c5edb3a432268e5831", type: .usdcArbitrum),
    EVMTokenRail(chainID: 42161, contract: "0xfd086bc7cd5c481dcc9c85ebe478a1c0b69fcbb9", type: .usdtArbitrum),
    EVMTokenRail(chainID: 56, contract: "0x8ac76a51cc950d9822d68b83fe1ad97b32cd580d", type: .usdcBsc),
    EVMTokenRail(chainID: 56, contract: "0x55d398326f99059ff775485246999027b3197955", type: .usdtBsc),
]

func evmTokenType(chainID: Int, contract: String) -> DestinationType? {
    let needle = contract.lowercased()
    return evmTokenRails.first { $0.chainID == chainID && $0.contract == needle }?.type
}

/// Address rails `addPayment` encrypts with one UUID secret.
/// Tron, TON, and Solana are included because `addPayment` still encrypts them.
/// They have no verify URI.
private let uuidSecretDestinationTypes: Set<DestinationType> = Set(
    [.bitcoinAddress, .usdtTron, .usdtTon, .usdtSolana, .usdcSolana] + evmTokenRails.map(\.type)
)

/// Address rails encrypted with a random `branta_secret` (not a derived key).
func isSecretKeyAddressType(_ type: DestinationType) -> Bool {
    uuidSecretDestinationTypes.contains(type)
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
