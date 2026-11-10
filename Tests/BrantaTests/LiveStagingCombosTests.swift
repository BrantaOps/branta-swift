import XCTest
@testable import Branta

/// Extra live staging POST→GET combinations beyond the dedicated polygon round-trips.
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

    private func polURI(recipient: String, encrypted: String, secret: String) -> String {
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "value", value: "50"),
            URLQueryItem(name: "user", value: "send"),
            URLQueryItem(name: "currency", value: "USD"),
            URLQueryItem(name: "branta_id", value: encrypted),
            URLQueryItem(name: "branta_secret", value: secret),
        ]
        return "pol:\(recipient)?\(components.percentEncodedQuery ?? "")"
    }

    private func bitcoinURI(address: String, encrypted: String, secret: String) -> String {
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "branta_id", value: encrypted),
            URLQueryItem(name: "branta_secret", value: secret),
        ]
        return "bitcoin:\(address)?\(components.percentEncodedQuery ?? "")"
    }

    private func mustAdd(_ svc: BrantaService, _ payment: Payment) async throws -> AddPaymentResult {
        try await svc.addPayment(payment)
    }

    private func mustStatus(_ svc: BrantaService, _ qr: String, _ want: VerifyStatus) async throws -> VerifyResult {
        let result = try await svc.verify(qr)
        XCTAssertEqual(result.status, want, qr)
        return result
    }

    func testBitcoinRoundTripMatchAndTamper() async throws {
        let svc = service()
        let added = try await mustAdd(svc, PaymentBuilder()
            .addDestination(btc, type: .bitcoinAddress)
            .setTTL(120)
            .build())
        let enc = added.payment.destinations[0].value
        let match = try await mustStatus(svc, bitcoinURI(address: btc, encrypted: enc, secret: added.secret), .match)
        XCTAssertEqual(match.matchedDestinations.count, 1)
        XCTAssertEqual(match.matchedDestinations[0].type, .bitcoinAddress)
        _ = try await mustStatus(svc, bitcoinURI(address: btcSw, encrypted: enc, secret: added.secret), .tampered)
        _ = try await mustStatus(svc, "bitcoin:\(btc)", .unknown)
    }

    func testUsdtUsdcDifferentAddressesBindOwnRail() async throws {
        let svc = service()
        let added = try await mustAdd(svc, PaymentBuilder()
            .addDestination(usdt, type: .usdtPolygon)
            .addDestination(usdc, type: .usdcPolygon)
            .setTTL(120)
            .build())
        var encUsdt = ""
        var encUsdc = ""
        for destination in added.payment.destinations {
            switch destination.type {
            case .usdtPolygon: encUsdt = destination.value
            case .usdcPolygon: encUsdc = destination.value
            default: break
            }
        }
        let usdtMatch = try await mustStatus(svc, polURI(recipient: usdt, encrypted: encUsdt, secret: added.secret), .match)
        XCTAssertEqual(usdtMatch.matchedDestinations.count, 1)
        XCTAssertEqual(usdtMatch.matchedDestinations[0].type, .usdtPolygon)
        let usdcMatch = try await mustStatus(svc, polURI(recipient: usdc, encrypted: encUsdc, secret: added.secret), .match)
        XCTAssertEqual(usdcMatch.matchedDestinations.count, 1)
        XCTAssertEqual(usdcMatch.matchedDestinations[0].type, .usdcPolygon)
    }

    func testUsdtUsdcSameAddressBothMatch() async throws {
        let svc = service()
        let added = try await mustAdd(svc, PaymentBuilder()
            .addDestination(usdt, type: .usdtPolygon)
            .addDestination(usdt, type: .usdcPolygon)
            .setTTL(120)
            .build())
        let enc = added.payment.destinations[0].value
        let match = try await mustStatus(svc, polURI(recipient: usdt, encrypted: enc, secret: added.secret), .match)
        XCTAssertEqual(match.matchedDestinations.count, 2)
    }

    func testBitcoinUsdtSiblingRailsIsolateByScheme() async throws {
        let svc = service()
        let added = try await mustAdd(svc, PaymentBuilder()
            .addDestination(btc, type: .bitcoinAddress)
            .addDestination(usdt, type: .usdtPolygon)
            .setTTL(120)
            .build())
        var encBtc = ""
        var encUsdt = ""
        for destination in added.payment.destinations {
            switch destination.type {
            case .bitcoinAddress: encBtc = destination.value
            case .usdtPolygon: encUsdt = destination.value
            default: break
            }
        }
        let btcMatch = try await mustStatus(svc, bitcoinURI(address: btc, encrypted: encBtc, secret: added.secret), .match)
        XCTAssertEqual(btcMatch.matchedDestinations.count, 1)
        XCTAssertEqual(btcMatch.matchedDestinations[0].type, .bitcoinAddress)
        let polMatch = try await mustStatus(svc, polURI(recipient: usdt, encrypted: encUsdt, secret: added.secret), .match)
        XCTAssertEqual(polMatch.matchedDestinations.count, 1)
        XCTAssertEqual(polMatch.matchedDestinations[0].type, .usdtPolygon)
        _ = try await mustStatus(svc, polURI(recipient: swap, encrypted: encUsdt, secret: added.secret), .tampered)
    }

    func testUsdtCaseInsensitiveAndWrongSecretUnknown() async throws {
        let svc = service()
        let added = try await mustAdd(svc, PaymentBuilder()
            .addDestination(usdt, type: .usdtPolygon)
            .setTTL(120)
            .build())
        let enc = added.payment.destinations[0].value
        _ = try await mustStatus(svc, polURI(recipient: usdt.lowercased(), encrypted: enc, secret: added.secret), .match)
        _ = try await mustStatus(
            svc,
            polURI(recipient: usdt, encrypted: enc, secret: "00000000-0000-0000-0000-000000000000"),
            .unknown
        )
        _ = try await mustStatus(svc, usdt, .unknown)
        _ = try await mustStatus(svc, "pol:\(usdt)?value=50&currency=USD", .unknown)
    }
}
