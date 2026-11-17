import XCTest
@testable import Branta

/// Extra live staging POST→GET combinations.
/// Skipped unless BRANTA_RUN_INTEGRATION=1 and BRANTA_API_KEY is set.
final class LiveStagingCombosTests: XCTestCase {
    override func setUpWithError() throws {
        if ProcessInfo.processInfo.environment["BRANTA_RUN_INTEGRATION"] != "1" {
            throw XCTSkip("Live lookups skipped unless BRANTA_RUN_INTEGRATION=1")
        }
        if (ProcessInfo.processInfo.environment["BRANTA_API_KEY"] ?? "").isEmpty {
            throw XCTSkip("Live POST skipped unless BRANTA_API_KEY is set")
        }
    }

    private let btc = "bc1qgw3dzmhnyvcswc9r0v0z0ajtp8ulm4nuyeahwr"
    private let usdt = "0x278297528c32eCa01295B0d2135984d3442ec963"
    private let usdc = "0xAb5801a7D398351b8bE11C439e05C5B3259aeC9B"
    private let swap = "0x1111111111111111111111111111111111111111"
    private let btcSw = "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"

    private func service() -> BrantaService {
        let options = BrantaApiOptions(
            environment: .staging,
            apiKey: ProcessInfo.processInfo.environment["BRANTA_API_KEY"]
        )
        let client = BrantaClient(defaultOptions: options)
        client.integrationMetricsToken = ProcessInfo.processInfo.environment["BRANTA_INTEGRATION_METRICS_TOKEN"] ?? ""
        return BrantaService(
            options: options,
            client: client,
            aes: AESEncryptionService(),
            secretGenerator: GuidSecretGenerator()
        )
    }

    private func rail(for type: DestinationType) -> EVMTokenRail {
        evmTokenRails.first { $0.type == type }!
    }

    /// ERC-681 transfer URI for one EVM rail, as a wallet would show it.
    private func transferURI(_ type: DestinationType, recipient: String, encrypted: String, secret: String) -> String {
        let rail = rail(for: type)
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "branta_id", value: encrypted),
            URLQueryItem(name: "branta_secret", value: secret),
        ]
        return "ethereum:\(rail.contract)@\(rail.chainID)/transfer?address=\(recipient)&uint256=1000000&\(components.percentEncodedQuery ?? "")"
    }

    private func bitcoinURI(address: String, encrypted: String, secret: String) -> String {
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "branta_id", value: encrypted),
            URLQueryItem(name: "branta_secret", value: secret),
        ]
        return "bitcoin:\(address)?\(components.percentEncodedQuery ?? "")"
    }

    private func mustStatus(_ svc: BrantaService, _ qr: String, _ want: VerifyStatus) async throws -> VerifyResult {
        let result = try await svc.verify(qr)
        XCTAssertEqual(result.status, want, qr)
        return result
    }

    func testBitcoinRoundTripMatchAndTamper() async throws {
        let svc = service()
        let added = try await svc.addPayment(
            PaymentBuilder().addDestination(btc, type: .bitcoinAddress).setTTL(120).build()
        )
        let enc = added.payment.destinations[0].value
        let match = try await mustStatus(svc, bitcoinURI(address: btc, encrypted: enc, secret: added.secret), .match)
        XCTAssertEqual(match.matchedDestinations.count, 1)
        XCTAssertEqual(match.matchedDestinations[0].type, .bitcoinAddress)
        _ = try await mustStatus(svc, bitcoinURI(address: btcSw, encrypted: enc, secret: added.secret), .tampered)
        _ = try await mustStatus(svc, "bitcoin:\(btc)", .unknown)
    }

    func testUsdtUsdcDifferentAddressesBindOwnRail() async throws {
        let svc = service()
        let added = try await svc.addPayment(
            PaymentBuilder()
                .addDestination(usdt, type: .usdtPolygon)
                .addDestination(usdc, type: .usdcPolygon)
                .setTTL(120)
                .build()
        )
        var encUsdt = ""
        var encUsdc = ""
        for destination in added.payment.destinations {
            switch destination.type {
            case .usdtPolygon: encUsdt = destination.value
            case .usdcPolygon: encUsdc = destination.value
            default: break
            }
        }
        let usdtMatch = try await mustStatus(
            svc, transferURI(.usdtPolygon, recipient: usdt, encrypted: encUsdt, secret: added.secret), .match
        )
        XCTAssertEqual(usdtMatch.matchedDestinations.map(\.type), [.usdtPolygon])
        let usdcMatch = try await mustStatus(
            svc, transferURI(.usdcPolygon, recipient: usdc, encrypted: encUsdc, secret: added.secret), .match
        )
        XCTAssertEqual(usdcMatch.matchedDestinations.map(\.type), [.usdcPolygon])
    }

    func testSameAddressUnderTwoTokensBindsOnlyTheScannedToken() async throws {
        let svc = service()
        let added = try await svc.addPayment(
            PaymentBuilder()
                .addDestination(usdt, type: .usdtPolygon)
                .addDestination(usdt, type: .usdcPolygon)
                .setTTL(120)
                .build()
        )
        var encUsdt = ""
        var encUsdc = ""
        for destination in added.payment.destinations {
            switch destination.type {
            case .usdtPolygon: encUsdt = destination.value
            case .usdcPolygon: encUsdc = destination.value
            default: break
            }
        }
        let usdtMatch = try await mustStatus(
            svc, transferURI(.usdtPolygon, recipient: usdt, encrypted: encUsdt, secret: added.secret), .match
        )
        XCTAssertEqual(usdtMatch.matchedDestinations.map(\.type), [.usdtPolygon])
        let usdcMatch = try await mustStatus(
            svc, transferURI(.usdcPolygon, recipient: usdt, encrypted: encUsdc, secret: added.secret), .match
        )
        XCTAssertEqual(usdcMatch.matchedDestinations.map(\.type), [.usdcPolygon])
        _ = try await mustStatus(
            svc, transferURI(.usdtPolygon, recipient: swap, encrypted: encUsdt, secret: added.secret), .tampered
        )
    }

    func testBitcoinAndUsdtSiblingRailsIsolateByType() async throws {
        let svc = service()
        let added = try await svc.addPayment(
            PaymentBuilder()
                .addDestination(btc, type: .bitcoinAddress)
                .addDestination(usdt, type: .usdtPolygon)
                .setTTL(120)
                .build()
        )
        var encBtc = ""
        var encUsdt = ""
        for destination in added.payment.destinations {
            switch destination.type {
            case .bitcoinAddress: encBtc = destination.value
            case .usdtPolygon: encUsdt = destination.value
            default: break
            }
        }
        let btcMatch = try await mustStatus(
            svc, bitcoinURI(address: btc, encrypted: encBtc, secret: added.secret), .match
        )
        XCTAssertEqual(btcMatch.matchedDestinations.map(\.type), [.bitcoinAddress])
        XCTAssertEqual(btcMatch.payments[0].destinations.first { $0.type == .usdtPolygon }?.isEncrypted, true)

        let usdtMatch = try await mustStatus(
            svc, transferURI(.usdtPolygon, recipient: usdt, encrypted: encUsdt, secret: added.secret), .match
        )
        XCTAssertEqual(usdtMatch.matchedDestinations.map(\.type), [.usdtPolygon])
        XCTAssertEqual(usdtMatch.payments[0].destinations.first { $0.type == .bitcoinAddress }?.isEncrypted, true)

        _ = try await mustStatus(
            svc, transferURI(.usdtPolygon, recipient: swap, encrypted: encUsdt, secret: added.secret), .tampered
        )
    }

    func testUsdtCaseInsensitiveWrongSecretAndRemovedSchemeUnknown() async throws {
        let svc = service()
        let added = try await svc.addPayment(
            PaymentBuilder().addDestination(usdt, type: .usdtPolygon).setTTL(120).build()
        )
        let enc = added.payment.destinations[0].value
        _ = try await mustStatus(
            svc, transferURI(.usdtPolygon, recipient: usdt.lowercased(), encrypted: enc, secret: added.secret), .match
        )
        _ = try await mustStatus(
            svc,
            transferURI(.usdtPolygon, recipient: usdt, encrypted: enc, secret: "00000000-0000-0000-0000-000000000000"),
            .unknown
        )
        _ = try await mustStatus(svc, usdt, .unknown)
        // The old pol: scheme no longer verifies, even with valid Branta params.
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "branta_id", value: enc),
            URLQueryItem(name: "branta_secret", value: added.secret),
        ]
        _ = try await mustStatus(svc, "pol:\(usdt)?value=50&\(components.percentEncodedQuery ?? "")", .unknown)
    }
}
