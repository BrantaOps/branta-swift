import XCTest
@testable import Branta

/// Live staging addPayment → verify for every rail.
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

    private static let bitcoinAddress = "bc1qxy2kgdygjrsqtzq2n0yrf2493p83kkfjhx0wlh"
    private static let bitcoinSwapped = "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"

    /// Mixed-case deposit per rail, so the lowercase-scan check differs from the stored text.
    private func deposit(for type: DestinationType) -> String {
        let index = evmTokenRails.firstIndex { $0.type == type }! + 1
        let hex = String(index, radix: 16)
        return "0xAb" + String(repeating: "1", count: 38 - hex.count) + hex
    }

    private static let swappedEvm = "0x" + String(repeating: "9", count: 40)

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

    private static func uniq() -> String {
        String(Int(Date().timeIntervalSince1970 * 1000), radix: 16) + String(Int.random(in: 0 ... 0xffffff), radix: 16)
    }

    func testBitcoinRoundTrip() async throws {
        let svc = service()
        let added = try await svc.addPayment(
            PaymentBuilder().addDestination(Self.bitcoinAddress, type: .bitcoinAddress).setTTL(180).build()
        )
        let encrypted = added.payment.destinations[0].value
        XCTAssertNotEqual(encrypted, Self.bitcoinAddress)

        let match = try await svc.verify(bitcoinURI(address: Self.bitcoinAddress, encrypted: encrypted, secret: added.secret))
        XCTAssertEqual(match.status, .match)
        XCTAssertEqual(match.matchedDestinations.map(\.type), [.bitcoinAddress])
        XCTAssertEqual(match.matchedDestinations[0].value, Self.bitcoinAddress)

        let tampered = try await svc.verify(bitcoinURI(address: Self.bitcoinSwapped, encrypted: encrypted, secret: added.secret))
        XCTAssertEqual(tampered.status, .tampered)

        let bare = try await svc.verify(Self.bitcoinAddress)
        XCTAssertEqual(bare.status, .unknown)
    }

    func testEveryEVMRailRoundTripsThroughERC681() async throws {
        let svc = service()
        for rail in evmTokenRails {
            let type = rail.type
            let address = deposit(for: type)
            let added = try await svc.addPayment(
                PaymentBuilder().addDestination(address, type: type).setTTL(180).build()
            )
            let encrypted = added.payment.destinations[0].value
            XCTAssertEqual(added.payment.destinations[0].type, type, type.rawValue)
            XCTAssertNotEqual(encrypted, address, type.rawValue)

            let match = try await svc.verify(
                transferURI(type, recipient: address, encrypted: encrypted, secret: added.secret)
            )
            XCTAssertEqual(match.status, .match, type.rawValue)
            XCTAssertEqual(match.matchedDestinations.map(\.type), [type], type.rawValue)
            XCTAssertEqual(match.matchedDestinations[0].value, address, type.rawValue)

            let folded = try await svc.verify(
                transferURI(type, recipient: address.lowercased(), encrypted: encrypted, secret: added.secret)
            )
            XCTAssertEqual(folded.status, .match, type.rawValue)

            let tampered = try await svc.verify(
                transferURI(type, recipient: Self.swappedEvm, encrypted: encrypted, secret: added.secret)
            )
            XCTAssertEqual(tampered.status, .tampered, type.rawValue)

            let bare = try await svc.verify(address)
            XCTAssertEqual(bare.status, .unknown, type.rawValue)

            let noBranta = try await svc.verify(
                "ethereum:\(rail.contract)@\(rail.chainID)/transfer?address=\(address)&uint256=1000000"
            )
            XCTAssertEqual(noBranta.status, .unknown, type.rawValue)
        }
    }

    func testTronTonAndSolanaStillEncryptOnAddPayment() async throws {
        let svc = service()
        let cases: [(DestinationType, String)] = [
            (.usdtTron, "T9yD14Nj9j7xAB4dbGeiX9h8unkKHxuWwb"),
            (.usdtTon, "EQDtFpEwcFAEcRe5mLVh2N6C0y-_tur3BYOM93pEZPw390by"),
            (.usdtSolana, "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB"),
            (.usdcSolana, "7EqQdEULxWcraVx3mXKFjc84LhCkMGZCkRuDofycyinf"),
        ]
        for (type, address) in cases {
            let added = try await svc.addPayment(PaymentBuilder().addDestination(address, type: type).setTTL(180).build())
            XCTAssertEqual(added.payment.destinations[0].type, type, type.rawValue)
            XCTAssertNotEqual(added.payment.destinations[0].value, address, type.rawValue)
            // No verify URI exists for these rails, so a bare address stays unknown.
            let bare = try await svc.verify(address)
            XCTAssertEqual(bare.status, .unknown, type.rawValue)
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
            XCTAssertEqual(match.matchedDestinations[0].value.lowercased(), value.lowercased(), type.rawValue)

            let miss = try await svc.verify(factory())
            XCTAssertEqual(miss.status, .unknown, type.rawValue)
        }
    }

    func testAnEthereumScanDoesNotBindAPolygonOnlyPayment() async throws {
        let address = deposit(for: .usdtPolygon)
        let svc = service()
        let added = try await svc.addPayment(
            PaymentBuilder().addDestination(address, type: .usdtPolygon).setTTL(180).build()
        )
        let encrypted = added.payment.destinations[0].value

        let cross = try await svc.verify(
            transferURI(.usdtEthereum, recipient: address, encrypted: encrypted, secret: added.secret)
        )
        XCTAssertEqual(cross.status, .unknown)

        let correct = try await svc.verify(
            transferURI(.usdtPolygon, recipient: address, encrypted: encrypted, secret: added.secret)
        )
        XCTAssertEqual(correct.status, .match)
    }

    func testADualTokenPaymentBindsOnlyTheScannedToken() async throws {
        let usdt = deposit(for: .usdtEthereum)
        let usdc = deposit(for: .usdcEthereum)
        let svc = service()
        let added = try await svc.addPayment(
            PaymentBuilder()
                .addDestination(usdt, type: .usdtEthereum)
                .addDestination(usdc, type: .usdcEthereum)
                .setTTL(180)
                .build()
        )
        let encryptedUsdt = added.payment.destinations[0].value

        let matchUsdt = try await svc.verify(
            transferURI(.usdtEthereum, recipient: usdt, encrypted: encryptedUsdt, secret: added.secret)
        )
        XCTAssertEqual(matchUsdt.status, .match)
        XCTAssertEqual(matchUsdt.matchedDestinations.map(\.type), [.usdtEthereum])
        XCTAssertEqual(matchUsdt.payments[0].destinations.first { $0.type == .usdcEthereum }?.isEncrypted, true)

        // A USDC scan carrying the USDT ciphertext decrypts the USDT row, but USDC has no matching address.
        let swapped = try await svc.verify(
            transferURI(.usdtEthereum, recipient: Self.swappedEvm, encrypted: encryptedUsdt, secret: added.secret)
        )
        XCTAssertEqual(swapped.status, .tampered)
    }
}
