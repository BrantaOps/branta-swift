import XCTest
@testable import Branta

/// Live staging addPayment → verify for every secret-key and derived-key rail.
/// Skipped unless BRANTA_RUN_INTEGRATION=1 and BRANTA_API_KEY is set.
final class MultiRailRoundTripTests: XCTestCase {
    override func setUpWithError() throws {
        if ProcessInfo.processInfo.environment["BRANTA_RUN_INTEGRATION"] != "1" {
            throw XCTSkip("Live lookups skipped unless BRANTA_RUN_INTEGRATION=1")
        }
        if (ProcessInfo.processInfo.environment["BRANTA_API_KEY"] ?? "").isEmpty {
            throw XCTSkip("Live POST skipped unless BRANTA_API_KEY is set")
        }
    }

    private struct SecretKeyRail {
        var type: DestinationType
        var scheme: String
        var address: String
        var swapped: String
        var caseFold: Bool = false
    }

    private static let secretKeyRails: [SecretKeyRail] = [
        .init(
            type: .bitcoinAddress,
            scheme: "bitcoin",
            address: "bc1qxy2kgdygjrsqtzq2n0yrf2493p83kkfjhx0wlh",
            swapped: "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"
        ),
        .init(
            type: .usdtPolygon,
            scheme: "pol",
            address: "0x278297528c32eCa01295B0d2135984d3442ec963",
            swapped: "0x1111111111111111111111111111111111111111",
            caseFold: true
        ),
        .init(
            type: .usdcPolygon,
            scheme: "pol",
            address: "0xAb5801a7D398351b8bE11C439e05C5B3259aeC9B",
            swapped: "0x2222222222222222222222222222222222222222",
            caseFold: true
        ),
        .init(
            type: .usdtEthereum,
            scheme: "eth",
            address: "0xBF5550253939187432Ef4dccE8089765d3DCb47f",
            swapped: "0x3333333333333333333333333333333333333333",
            caseFold: true
        ),
        .init(
            type: .usdcEthereum,
            scheme: "eth",
            address: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
            swapped: "0x4444444444444444444444444444444444444444",
            caseFold: true
        ),
        .init(
            type: .usdtBsc,
            scheme: "bsc",
            address: "0x55d398326f99059fF775485246999027B3197955",
            swapped: "0x5555555555555555555555555555555555555555",
            caseFold: true
        ),
        .init(
            type: .usdcBsc,
            scheme: "bsc",
            address: "0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d",
            swapped: "0x6666666666666666666666666666666666666666",
            caseFold: true
        ),
        .init(
            type: .usdtTron,
            scheme: "tron",
            address: "T9yD14Nj9j7xAB4dbGeiX9h8unkKHxuWwb",
            swapped: "TXyZ1111111111111111111111111111111"
        ),
        .init(
            type: .usdtTon,
            scheme: "ton",
            address: "EQDtFpEwcFAEcRe5mLVh2N6C0y-_tur3BYOM93pEZPw390by",
            swapped: "EQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAM9c"
        ),
        .init(
            type: .usdtSolana,
            scheme: "sol",
            address: "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB",
            swapped: "11111111111111111111111111111111"
        ),
        .init(
            type: .usdcSolana,
            scheme: "sol",
            address: "7EqQdEULxWcraVx3mXKFjc84LhCkMGZCkRuDofycyinf",
            swapped: "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"
        ),
    ]

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

    private func secretKeyURI(scheme: String, recipient: String, encrypted: String, secret: String) -> String {
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "branta_id", value: encrypted),
            URLQueryItem(name: "branta_secret", value: secret),
        ]
        return "\(scheme):\(recipient)?\(components.percentEncodedQuery ?? "")"
    }

    private static func uniq() -> String {
        String(Int(Date().timeIntervalSince1970 * 1000), radix: 16) + String(Int.random(in: 0 ... 0xffffff), radix: 16)
    }

    func testSecretKeyRailsRoundTrip() async throws {
        let svc = service()
        for rail in Self.secretKeyRails {
            let payment = PaymentBuilder()
                .addDestination(rail.address, type: rail.type)
                .setTTL(180)
                .build()
            let added = try await svc.addPayment(payment)
            let encrypted = added.payment.destinations[0].value
            XCTAssertEqual(added.payment.destinations[0].type, rail.type, rail.type.rawValue)
            XCTAssertNotEqual(encrypted, rail.address, rail.type.rawValue)

            let match = try await svc.verify(
                secretKeyURI(scheme: rail.scheme, recipient: rail.address, encrypted: encrypted, secret: added.secret)
            )
            XCTAssertEqual(match.status, .match, rail.type.rawValue)
            XCTAssertEqual(match.matchedDestinations.count, 1, rail.type.rawValue)
            XCTAssertEqual(match.matchedDestinations[0].type, rail.type, rail.type.rawValue)
            if rail.caseFold {
                XCTAssertEqual(
                    match.matchedDestinations[0].value.lowercased(),
                    rail.address.lowercased(),
                    rail.type.rawValue
                )
                let folded = try await svc.verify(
                    secretKeyURI(
                        scheme: rail.scheme,
                        recipient: rail.address.lowercased(),
                        encrypted: encrypted,
                        secret: added.secret
                    )
                )
                XCTAssertEqual(folded.status, .match, rail.type.rawValue)
            } else {
                XCTAssertEqual(match.matchedDestinations[0].value, rail.address, rail.type.rawValue)
            }

            let tampered = try await svc.verify(
                secretKeyURI(scheme: rail.scheme, recipient: rail.swapped, encrypted: encrypted, secret: added.secret)
            )
            XCTAssertEqual(tampered.status, .tampered, rail.type.rawValue)

            let bare = try await svc.verify(rail.address)
            XCTAssertEqual(bare.status, .unknown, rail.type.rawValue)

            let noBranta = try await svc.verify("\(rail.scheme):\(rail.address)")
            XCTAssertEqual(noBranta.status, .unknown, rail.type.rawValue)
        }
    }

    func testDerivedKeyRailsRoundTrip() async throws {
        let svc = service()
        let cases: [(DestinationType, () -> String)] = [
            (.bolt11, { "lnbc\(Self.uniq())n1ptest" }),
            (.arkAddress, { "ark1qqroundtrip\(Self.uniq())" }),
            (.silentPayment, { "sp1qqroundtrip\(Self.uniq())" }),
        ]
        for (type, factory) in cases {
            let value = factory()
            let payment = PaymentBuilder().addDestination(value, type: type).setTTL(180).build()
            let added = try await svc.addPayment(payment)
            XCTAssertEqual(added.payment.destinations[0].type, type, type.rawValue)
            XCTAssertNotEqual(added.payment.destinations[0].value, value, type.rawValue)

            let match = try await svc.verify(value)
            XCTAssertEqual(match.status, .match, type.rawValue)
            XCTAssertEqual(match.matchedDestinations[0].type, type, type.rawValue)
            XCTAssertEqual(
                match.matchedDestinations[0].value.lowercased(),
                value.lowercased(),
                type.rawValue
            )

            let miss = try await svc.verify(factory())
            XCTAssertEqual(miss.status, .unknown, type.rawValue)
        }
    }

    func testCrossSchemeEthDoesNotBindPolygonOnlyPayment() async throws {
        let address = "0x278297528c32eCa01295B0d2135984d3442ec963"
        let svc = service()
        let payment = PaymentBuilder()
            .addDestination(address, type: .usdtPolygon)
            .setTTL(180)
            .build()
        let added = try await svc.addPayment(payment)
        let encrypted = added.payment.destinations[0].value

        let cross = try await svc.verify(
            secretKeyURI(scheme: "eth", recipient: address, encrypted: encrypted, secret: added.secret)
        )
        XCTAssertEqual(cross.status, .unknown)

        let correct = try await svc.verify(
            secretKeyURI(scheme: "pol", recipient: address, encrypted: encrypted, secret: added.secret)
        )
        XCTAssertEqual(correct.status, .match)
    }

    func testEthDualTokenMatchIfAny() async throws {
        let usdt = "0xBF5550253939187432Ef4dccE8089765d3DCb47f"
        let usdc = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
        let svc = service()
        let payment = PaymentBuilder()
            .addDestination(usdt, type: .usdtEthereum)
            .addDestination(usdc, type: .usdcEthereum)
            .setTTL(180)
            .build()
        let added = try await svc.addPayment(payment)
        let encryptedUsdt = added.payment.destinations[0].value

        let matchUsdt = try await svc.verify(
            secretKeyURI(scheme: "eth", recipient: usdt, encrypted: encryptedUsdt, secret: added.secret)
        )
        XCTAssertEqual(matchUsdt.status, .match)
        XCTAssertEqual(matchUsdt.matchedDestinations.map(\.type), [.usdtEthereum])
        let usdcDest = matchUsdt.payments[0].destinations.first { $0.type == .usdcEthereum }
        XCTAssertEqual(usdcDest?.isEncrypted, true)

        let matchUsdc = try await svc.verify(
            secretKeyURI(scheme: "eth", recipient: usdc, encrypted: encryptedUsdt, secret: added.secret)
        )
        XCTAssertEqual(matchUsdc.status, .match)
        XCTAssertEqual(matchUsdc.matchedDestinations.map(\.type), [.usdcEthereum])

        let swapped = try await svc.verify(
            secretKeyURI(
                scheme: "eth",
                recipient: "0x9999999999999999999999999999999999999999",
                encrypted: encryptedUsdt,
                secret: added.secret
            )
        )
        XCTAssertEqual(swapped.status, .tampered)
    }
}
