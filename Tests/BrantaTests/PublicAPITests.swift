import XCTest
import Branta

/// Consumer-surface lock. Uses `import Branta` (not `@testable`) so only public API compiles.
final class PublicAPITests: XCTestCase {
    func testConsumerTypesAreReachable() {
        XCTAssertEqual(DestinationType.usdtEthereum.rawValue, "usdt_ethereum")
        XCTAssertEqual(DestinationType.usdcSolana.rawValue, "usdc_solana")
        XCTAssertEqual(DestinationType.usdtTon.rawValue, "usdt_ton")
        XCTAssertEqual(DestinationType.usdtBase.rawValue, "usdt_base")
        XCTAssertEqual(DestinationType.usdcBase.rawValue, "usdc_base")
        XCTAssertEqual(DestinationType.usdtArbitrum.rawValue, "usdt_arbitrum")
        XCTAssertEqual(DestinationType.usdcArbitrum.rawValue, "usdc_arbitrum")
        XCTAssertNil(DestinationType(rawValue: "usdc_ton"))

        XCTAssertEqual(VerifyStatus.match.rawValue, "match")
        XCTAssertEqual(BrantaEnvironment.staging.url, "https://staging.guardrail.branta.pro")

        let options = BrantaApiOptions(environment: .localhost, apiKey: "k")
        let service = BrantaService(options: options)
        XCTAssertNotNil(service)

        let payment = PaymentBuilder()
            .addDestination("bc1qexample", type: .bitcoinAddress)
            .build()
        XCTAssertEqual(payment.destinations.count, 1)

        let verify = VerifyResult(status: .unknown, verifyURL: "https://example/v2/verify/x")
        XCTAssertEqual(verify.status, .unknown)
        XCTAssertTrue(verify.matchedDestinations.isEmpty)

        let error = BrantaPaymentError(message: "platformLogoURL domain does not match the configured environment")
        XCTAssertTrue(error.message.contains("platformLogoURL"))
    }

    func testPublicInitDoesNotRequireDeprecatedHMAC() {
        let options = BrantaApiOptions(environment: .production, apiKey: "parent")
        XCTAssertEqual(options.apiKey, "parent")
        XCTAssertEqual(options.environment, .production)
    }
}
