import XCTest
@testable import Branta

final class PolygonRoundTripTests: XCTestCase {
    override func setUpWithError() throws {
        if ProcessInfo.processInfo.environment["BRANTA_RUN_INTEGRATION"] != "1" {
            throw XCTSkip("Live lookups skipped unless BRANTA_RUN_INTEGRATION=1")
        }
        if (ProcessInfo.processInfo.environment["BRANTA_API_KEY"] ?? "").isEmpty {
            throw XCTSkip("Live POST skipped unless BRANTA_API_KEY is set")
        }
    }

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

    func testStagingUsdtPolygonRoundTrip() async throws {
        let address = "0x278297528c32eCa01295B0d2135984d3442ec963"
        let swapped = "0x1111111111111111111111111111111111111111"
        let svc = service()
        let payment = PaymentBuilder()
            .addDestination(address, type: .usdtPolygon)
            .setTTL(120)
            .build()
        let added = try await svc.addPayment(payment)
        let encrypted = added.payment.destinations[0].value
        XCTAssertEqual(added.payment.destinations[0].type, .usdtPolygon)

        let match = try await svc.verify(polURI(recipient: address, encrypted: encrypted, secret: added.secret))
        XCTAssertEqual(match.status, .match)
        XCTAssertEqual(match.payments[0].destinations[0].type, .usdtPolygon)
        XCTAssertEqual(match.payments[0].destinations[0].value.lowercased(), address.lowercased())

        let lower = try await svc.verify(polURI(recipient: address.lowercased(), encrypted: encrypted, secret: added.secret))
        XCTAssertEqual(lower.status, .match)

        let tampered = try await svc.verify(polURI(recipient: swapped, encrypted: encrypted, secret: added.secret))
        XCTAssertEqual(tampered.status, .tampered)

        let bare = try await svc.verify(address)
        XCTAssertEqual(bare.status, .unknown)

        let polBare = try await svc.verify("pol:\(address)?value=50&currency=USD")
        XCTAssertEqual(polBare.status, .unknown)
    }

    func testStagingUsdcPolygonRoundTrip() async throws {
        let address = "0xAb5801a7D398351b8bE11C439e05C5B3259aeC9B"
        let swapped = "0x1111111111111111111111111111111111111111"
        let svc = service()
        let payment = PaymentBuilder()
            .addDestination(address, type: .usdcPolygon)
            .setTTL(120)
            .build()
        let added = try await svc.addPayment(payment)
        let encrypted = added.payment.destinations[0].value

        let match = try await svc.verify(polURI(recipient: address, encrypted: encrypted, secret: added.secret))
        XCTAssertEqual(match.status, .match)
        XCTAssertEqual(match.matchedDestinations[0].type, .usdcPolygon)

        let tampered = try await svc.verify(polURI(recipient: swapped, encrypted: encrypted, secret: added.secret))
        XCTAssertEqual(tampered.status, .tampered)
    }
}
