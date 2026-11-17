import XCTest
@testable import Branta

final class FakeClient: BrantaClienting {
    var getImpl: (String, BrantaApiOptions?) async throws -> [Payment] = { _, _ in [] }
    var postImpl: (Payment, BrantaApiOptions?) async throws -> Payment? = { payment, _ in payment }
    var keyImpl: (BrantaApiOptions?) async throws -> Bool = { _ in false }
    var gets: [String] = []
    var posts: [Payment] = []
    var keyCalls: [BrantaApiOptions?] = []

    func getPayments(destinationValue: String, options: BrantaApiOptions?) async throws -> [Payment] {
        gets.append(destinationValue)
        return try await getImpl(destinationValue, options)
    }

    func postPayment(_ payment: Payment, options: BrantaApiOptions?) async throws -> Payment? {
        posts.append(payment)
        return try await postImpl(payment, options)
    }

    func isAPIKeyValid(options: BrantaApiOptions?) async throws -> Bool {
        keyCalls.append(options)
        return try await keyImpl(options)
    }
}

final class FakeAES: AESEncrypting {
    struct EncryptCall: Hashable {
        var value: String
        var secret: String
        var deterministic: Bool
    }

    struct DecryptCall: Hashable {
        var value: String
        var secret: String
    }

    var encryptMap: [EncryptCall: String] = [:]
    var decryptMap: [DecryptCall: String] = [:]
    var encryptCalls: [EncryptCall] = []
    var decryptCalls: [DecryptCall] = []
    var encryptImpl: ((String, String, Bool) throws -> String)?
    var decryptImpl: ((String, String) throws -> String)?

    func encrypt(value: String, secret: String, deterministicNonce: Bool) throws -> String {
        let call = EncryptCall(value: value, secret: secret, deterministic: deterministicNonce)
        encryptCalls.append(call)
        if let encryptImpl { return try encryptImpl(value, secret, deterministicNonce) }
        if let result = encryptMap[call] { return result }
        return "enc:" + value
    }

    func decrypt(encryptedValue: String, secret: String) throws -> String {
        let call = DecryptCall(value: encryptedValue, secret: secret)
        decryptCalls.append(call)
        if let decryptImpl { return try decryptImpl(encryptedValue, secret) }
        if let result = decryptMap[call] { return result }
        throw AESError(message: "Decryption failed: auth tag mismatch")
    }
}

final class FakeSecrets: SecretGenerating {
    var values: [String]
    var index = 0
    var deterministicNonce: Bool
    init(_ values: [String], deterministicNonce: Bool = false) {
        self.values = values
        self.deterministicNonce = deterministicNonce
    }

    func generate() -> String {
        let value = values.isEmpty ? "secret" : values[min(index, values.count - 1)]
        index += 1
        return value
    }
}

final class ServiceTests: XCTestCase {
    private let addr = "bc1q6745z6cy3u0k9nprurh3x804c4r7u3u8vxca2n"
    private let invoice = "lnbc10u1p4w23tzpp5example"
    private let bitcoin = "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"
    private let swapped = "1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2"

    private var client: FakeClient!
    private var aes: FakeAES!
    private var service: BrantaService!

    override func setUp() {
        super.setUp()
        client = FakeClient()
        aes = FakeAES()
        service = BrantaService(
            options: BrantaApiOptions(environment: .localhost, apiKey: "test-api-key"),
            client: client,
            aes: aes,
            secretGenerator: FakeSecrets(["bitcoin-secret"])
        )
    }

    private func encrypted(_ value: String, id: String, type: DestinationType) -> Destination {
        Destination(value: value, type: type, id: id, isEncrypted: true)
    }

    func testBareAddressIsUnknownWithoutLookup() async throws {
        let result = try await service.verify("bitcoin:\(addr)")
        XCTAssertEqual(result.status, .unknown)
        XCTAssertTrue(result.payments.isEmpty)
        XCTAssertTrue(client.gets.isEmpty)
        XCTAssertTrue(result.verifyURL.contains("/v2/verify/\(addr)"))
        XCTAssertFalse(result.verifyURL.contains("#"))
    }

    func testTestnetAddressIsUnknownWithoutLookup() async throws {
        let result = try await service.verify("tb1qshra2mlujc9wfscvn4d8aqpyqgxzl55853xg7s")
        XCTAssertEqual(result.status, .unknown)
        XCTAssertTrue(client.gets.isEmpty)
    }

    func testBolt11MatchDecryptsToTheScannedInvoice() async throws {
        client.getImpl = { _, _ in [Payment(destinations: [self.encrypted("cipher", id: "zk-1", type: .bolt11)])] }
        aes.decryptMap[.init(value: "cipher", secret: normalizedHash(invoice))] = invoice
        let result = try await service.verify("lightning:\(invoice)")
        XCTAssertEqual(result.status, .match)
        XCTAssertEqual(result.payments[0].destinations[0].value, invoice)
        XCTAssertTrue(result.verifyURL.contains("#k-zk-1="))
        XCTAssertEqual(client.gets, ["enc:\(invoice)"])
    }

    func testBolt11DifferentPlaintextIsTampered() async throws {
        client.getImpl = { _, _ in [Payment(destinations: [self.encrypted("cipher", id: "zk-1", type: .bolt11)])] }
        aes.decryptImpl = { _, _ in "lnbc1other" }
        let result = try await service.verify(invoice)
        XCTAssertEqual(result.status, .tampered)
        XCTAssertTrue(result.payments.isEmpty)
        XCTAssertEqual(result.verifyURL, "http://localhost:3000/v2/verify/\(invoice)")
    }

    func testBolt11MatchIsCaseInsensitive() async throws {
        client.getImpl = { _, _ in [Payment(destinations: [self.encrypted("cipher", id: "zk-1", type: .bolt11)])] }
        aes.decryptImpl = { _, _ in self.invoice }
        let result = try await service.verify(invoice.uppercased())
        XCTAssertEqual(result.status, .match)
        XCTAssertEqual(result.payments[0].destinations[0].value, invoice)
    }

    func testOnChainMatch() async throws {
        client.getImpl = { lookup, _ in
            XCTAssertEqual(lookup, "cipher-id")
            return [Payment(destinations: [self.encrypted("cipher", id: "zk-1", type: .bitcoinAddress)])]
        }
        aes.decryptImpl = { _, _ in self.addr }
        let qr = "bitcoin:\(addr)?branta_id=cipher-id&branta_secret=the-secret"
        let result = try await service.verify(qr)
        XCTAssertEqual(result.status, .match)
        XCTAssertEqual(result.payments[0].destinations[0].value, addr)
        XCTAssertEqual(result.matchedDestinations.count, 1)
        XCTAssertEqual(result.matchedDestinations[0].value, addr)
        XCTAssertTrue(result.verifyURL.hasSuffix("/v2/verify/cipher-id#k-zk-1=the-secret"))
    }

    func testSwappedAddressIsTampered() async throws {
        let other = "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"
        client.getImpl = { _, _ in [Payment(destinations: [self.encrypted("cipher", id: "zk-1", type: .bitcoinAddress)])] }
        aes.decryptImpl = { _, _ in self.addr }
        let qr = "bitcoin:\(other)?branta_id=cipher-id&branta_secret=the-secret"
        let result = try await service.verify(qr)
        XCTAssertEqual(result.status, .tampered)
        XCTAssertTrue(result.payments.isEmpty)
        XCTAssertFalse(result.verifyURL.contains("#"))
    }

    func testBrantaParamsWithoutPayableDestinationAreUnknown() async throws {
        let result = try await service.verify("bitcoin:?branta_id=cipher-id&branta_secret=the-secret")
        XCTAssertEqual(result.status, .unknown)
        XCTAssertTrue(client.gets.isEmpty)
    }

    func testUnverifiableInstructionIsUnknownWithoutLookup() async throws {
        let result = try await service.verify("bitcoin:\(addr)?lno=lno1qqexample")
        XCTAssertEqual(result.status, .unknown)
        XCTAssertTrue(client.gets.isEmpty)
    }

    func testServerErrorIsIncomplete() async throws {
        client.getImpl = { _, _ in throw LookupFailure.incomplete }
        let result = try await service.verify(invoice)
        XCTAssertEqual(result.status, .incomplete)
        XCTAssertEqual(result.verifyURL, "http://localhost:3000/v2/verify/\(invoice)")
    }

    func testMalformedLookupIsIncomplete() async throws {
        // Client maps decode failures to LookupFailure.incomplete; verify must surface status, not throw.
        client.getImpl = { _, _ in throw LookupFailure.incomplete }
        let result = try await service.verify(invoice)
        XCTAssertEqual(result.status, .incomplete)
        XCTAssertTrue(result.payments.isEmpty)
        XCTAssertTrue(result.matchedDestinations.isEmpty)
    }

    func testLogoMismatchStillErrors() async {
        client.getImpl = { _, _ in throw BrantaPaymentError(message: "platformLogoURL domain does not match the configured environment") }
        do {
            _ = try await service.verify(invoice)
            XCTFail("expected throw")
        } catch let error as BrantaPaymentError {
            XCTAssertTrue(error.message.contains("platformLogoURL"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testNotFoundIsUnknown() async throws {
        client.getImpl = { _, _ in [] }
        let result = try await service.verify(invoice)
        XCTAssertEqual(result.status, .unknown)
        XCTAssertTrue(result.payments.isEmpty)
    }

    func testAddPaymentLeavesCallerPlaintext() async throws {
        var payment = PaymentBuilder()
            .addDestination(addr, type: .bitcoinAddress)
            .setDescription("Invoice")
            .build()
        payment.destinations[0].id = "zk-1"
        let posting = BrantaService(
            options: BrantaApiOptions(environment: .localhost),
            client: client,
            aes: aes,
            secretGenerator: FakeSecrets(["dek", "bitcoin-secret"])
        )
        let result = try await posting.addPayment(payment)
        XCTAssertEqual(payment.destinations[0].value, addr)
        XCTAssertEqual(payment.description, "Invoice")
        XCTAssertNil(payment.metadata)
        XCTAssertEqual(client.posts[0].destinations[0].value, "enc:\(addr)")
        XCTAssertNil(client.posts[0].description)
        let folded = aes.encryptCalls.first { $0.secret == "dek" }
        XCTAssertEqual(folded?.value.contains("Invoice"), true)
        XCTAssertEqual(client.posts[0].metadata, "enc:\(folded?.value ?? "")")
        XCTAssertEqual(result.secret, "bitcoin-secret")
    }

    func testAddPaymentRetryEncryptsTheOriginalAddress() async throws {
        var calls = 0
        client.postImpl = { payment, _ in
            calls += 1
            if calls == 1 { throw BrantaPaymentError(message: "request failed with status 500") }
            return payment
        }
        aes.encryptImpl = { value, secret, _ in "enc-\(secret):\(value)" }
        let payment = Payment(destinations: [Destination(value: addr, type: .bitcoinAddress, id: "zk-1")])
        let posting = BrantaService(
            options: BrantaApiOptions(environment: .localhost),
            client: client,
            aes: aes,
            secretGenerator: FakeSecrets(["first", "retry"])
        )
        do {
            _ = try await posting.addPayment(payment)
            XCTFail("expected post failure")
        } catch is BrantaPaymentError {}
        XCTAssertEqual(payment.destinations[0].value, addr)
        let result = try await posting.addPayment(payment)
        XCTAssertTrue(result.payment.destinations[0].value.contains("retry:\(addr)"))
        XCTAssertFalse(client.posts[1].destinations[0].value.contains("enc-first"))
    }

    func testAddPaymentBolt11UsesDerivedKey() async throws {
        aes.encryptImpl = { value, secret, deterministic in
            XCTAssertTrue(deterministic)
            XCTAssertEqual(secret, normalizedHash(self.invoice))
            XCTAssertEqual(value, self.invoice)
            return "cipher"
        }
        let payment = Payment(destinations: [Destination(value: invoice.uppercased(), type: .bolt11, id: "zk-1")])
        _ = try await service.addPayment(payment)
        XCTAssertEqual(payment.destinations[0].value, invoice.uppercased())
        XCTAssertEqual(client.posts[0].destinations[0].value, "cipher")
    }

    func testAddPaymentUnsupportedTypeLeavesCallerUnchanged() async {
        let payment = Payment(destinations: [Destination(value: "user@example.com", id: "zk-1")])
        do {
            _ = try await service.addPayment(payment)
            XCTFail("expected throw")
        } catch let error as BrantaPaymentError {
            XCTAssertEqual(error.message, "destination type '' cannot be encrypted")
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(payment.destinations[0].value, "user@example.com")
        XCTAssertTrue(client.posts.isEmpty)
    }

    func testAddPaymentEmptyResponseErrors() async {
        client.postImpl = { _, _ in nil }
        let payment = Payment(destinations: [Destination(value: addr, type: .bitcoinAddress)])
        do {
            _ = try await service.addPayment(payment)
            XCTFail("expected throw")
        } catch let error as BrantaPaymentError {
            XCTAssertEqual(error.message, "No payment returned from server.")
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(payment.destinations[0].value, addr)
    }

    func testFragmentEncodesReservedCharacters() async throws {
        client.getImpl = { _, _ in [Payment(destinations: [self.encrypted("cipher", id: "a b", type: .bolt11)])] }
        aes.encryptImpl = { _, _, _ in "lookup" }
        aes.decryptImpl = { _, _ in self.invoice }
        let result = try await service.verify(invoice)
        XCTAssertEqual(result.status, .match)
        XCTAssertTrue(result.verifyURL.contains("#k-a%20b="))
    }

    func testMetadataDecryptLiftsDescription() async throws {
        let meta = #"{"description":"Invoice"}"#
        var destination = encrypted("cipher", id: "zk-1", type: .bitcoinAddress)
        destination.encryptedDek = "enc-dek"
        client.getImpl = { _, _ in [Payment(destinations: [destination], metadata: "enc-meta")] }
        aes.decryptImpl = { value, _ in
            switch value {
            case "cipher": return self.addr
            case "enc-dek": return "dek"
            case "enc-meta": return meta
            default: throw AESError(message: value)
            }
        }
        let result = try await service.verify("bitcoin:\(addr)?branta_id=cipher-id&branta_secret=the-secret")
        XCTAssertEqual(result.status, .match)
        XCTAssertEqual(result.payments[0].description, "Invoice")
        XCTAssertEqual(result.payments[0].metadata, meta)
    }

    func testConflictingOnChainAddressesAreTamperedBeforeLookup() async throws {
        let qr = "bitcoin:\(addr)?bc=\(bitcoin)&branta_id=cipher-id&branta_secret=the-secret"
        let result = try await service.verify(qr)
        XCTAssertEqual(result.status, .tampered)
        XCTAssertTrue(client.gets.isEmpty)
    }

    func testAttackerLegsAndWrongSecretAreUnknown() async throws {
        client.getImpl = { _, _ in [Payment(destinations: [self.encrypted("cipher", id: "zk-1", type: .bitcoinAddress)])] }
        aes.decryptMap[.init(value: "cipher", secret: "the-secret")] = bitcoin
        let legs = [
            "bitcoin:\(bitcoin)?branta_id=cipher&branta_secret=the-secret&lightning=lnbc1attacker",
            "bitcoin:\(bitcoin)?branta_id=cipher&branta_secret=the-secret&ark=ark1attacker",
            "bitcoin:\(bitcoin)?branta_id=cipher&branta_secret=the-secret&sp=sp1attacker",
            "bitcoin:\(bitcoin)?branta_id=cipher&branta_secret=wrong-secret",
        ]
        for qr in legs {
            let result = try await service.verify(qr)
            XCTAssertEqual(result.status, .unknown, qr)
            XCTAssertTrue(result.payments.isEmpty, qr)
        }
    }

    func testBech32CaseMatchesAndBase58DoesNot() async throws {
        let bech32 = "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"
        client.getImpl = { _, _ in [Payment(destinations: [self.encrypted("cipher", id: "zk-1", type: .bitcoinAddress)])] }
        aes.decryptImpl = { _, _ in bech32 }
        let upper = try await service.verify("bitcoin:\(bech32.uppercased())?branta_id=cipher-id&branta_secret=the-secret")
        XCTAssertEqual(upper.status, .match)
        XCTAssertEqual(upper.payments[0].destinations[0].value, bech32)

        aes.decryptImpl = { _, _ in self.bitcoin }
        let lowered = try await service.verify("bitcoin:\(bitcoin.lowercased())?branta_id=cipher-id&branta_secret=the-secret")
        XCTAssertEqual(lowered.status, .tampered)
    }

    func testBip321BcMatchResolves() async throws {
        client.getImpl = { _, _ in [Payment(destinations: [self.encrypted("cipher", id: "zk-1", type: .bitcoinAddress)])] }
        aes.decryptImpl = { _, _ in self.bitcoin }
        let result = try await service.verify("bitcoin:?bc=\(bitcoin)&branta_id=cipher-id&branta_secret=the-secret")
        XCTAssertEqual(result.status, .match)
        XCTAssertEqual(result.payments[0].destinations[0].value, bitcoin)
        XCTAssertFalse(result.payments[0].destinations[0].isEncrypted)
    }

    func testBolt12AndLNURLAreUnknownWithoutLookup() async throws {
        let bolt12 = try await service.verify("lightning:lno1qqexample")
        let lnurl = try await service.verify("lightning:lnurl1qqexample")
        let pay = try await service.verify("bitcoin:\(bitcoin)?pay=bitcoin:\(swapped)&branta_id=cipher&branta_secret=the-secret")
        XCTAssertEqual(bolt12.status, .unknown)
        XCTAssertEqual(lnurl.status, .unknown)
        XCTAssertEqual(pay.status, .unknown)
        XCTAssertTrue(client.gets.isEmpty)
    }

    func testZkFalseSkipsDecrypt() async throws {
        client.getImpl = { _, _ in
            [Payment(destinations: [Destination(value: "cipher", type: .bitcoinAddress, id: "zk-1", isEncrypted: false)])]
        }
        let result = try await service.verify("bitcoin:\(addr)?branta_id=cipher-id&branta_secret=the-secret")
        XCTAssertEqual(result.status, .unknown)
        XCTAssertTrue(aes.decryptCalls.isEmpty)
    }

    func testIsAPIKeyValidPassesThrough() async throws {
        client.keyImpl = { _ in true }
        let options = BrantaApiOptions(apiKey: "child")
        let valid = try await service.isAPIKeyValid(options: options)
        XCTAssertTrue(valid)
        XCTAssertEqual(client.keyCalls.last ?? nil, options)
    }

    private let usdtPolygonAddr = "0x278297528c32eCa01295B0d2135984d3442ec963"
    private let usdcPolygonAddr = "0xAb5801a7D398351b8bE11C439e05C5B3259aeC9B"
    private let siblingUsdtAddr = "0x2222222222222222222222222222222222222222"
    private let swappedEvmAddr = "0x" + String(repeating: "f", count: 40)
    private let usdtEthereumAddr = "0xBF5550253939187432Ef4dccE8089765d3DCb47f"
    private let usdcEthereumAddr = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
    private let usdtTronAddr = "T9yD14Nj9j7xAB4dbGeiX9h8unkKHxuWwb"
    private let usdtTonAddr = "EQDtFpEwcFAEcRe5mLVh2N6C0y-_tur3BYOM93pEZPw390by"
    private let usdtSolanaAddr = "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB"
    private let usdcSolanaAddr = "7EqQdEULxWcraVx3mXKFjc84LhCkMGZCkRuDofycyinf"

    private func rail(for type: DestinationType) -> EVMTokenRail {
        evmTokenRails.first { $0.type == type }!
    }

    /// ERC-681 transfer URI for one EVM rail, with the Branta params.
    private func transferURI(
        _ type: DestinationType,
        _ address: String,
        encrypted: String,
        secret: String = "the-secret",
        amount: String = "1000000"
    ) -> String {
        let rail = rail(for: type)
        return "ethereum:\(rail.contract)@\(rail.chainID)/transfer?address=\(address)&uint256=\(amount)&branta_id=\(encrypted)&branta_secret=\(secret)"
    }

    /// One mixed-case deposit per rail, so a payment holding two rails never shares an address
    /// and a lowercase scan still differs from the stored text.
    private func deposit(for type: DestinationType) -> String {
        let index = evmTokenRails.firstIndex { $0.type == type }! + 1
        let hex = String(index, radix: 16)
        return "0xAb" + String(repeating: "1", count: 38 - hex.count) + hex
    }

    // MARK: Polygon

    func testPolygonUSDTMatchIgnoresAmount() async throws {
        client.getImpl = { lookup, _ in
            XCTAssertEqual(lookup, "enc-usdt")
            return [Payment(destinations: [self.encrypted("cipher-usdt", id: "zk-usdt", type: .usdtPolygon)])]
        }
        aes.decryptImpl = { value, secret in
            XCTAssertEqual(value, "cipher-usdt")
            XCTAssertEqual(secret, "the-secret")
            return self.usdtPolygonAddr
        }
        let result = try await service.verify(transferURI(.usdtPolygon, usdtPolygonAddr, encrypted: "enc-usdt"))
        XCTAssertEqual(result.status, .match)
        XCTAssertEqual(result.payments[0].destinations[0].type, .usdtPolygon)
        XCTAssertEqual(result.payments[0].destinations[0].value, usdtPolygonAddr)
        XCTAssertEqual(result.matchedDestinations.count, 1)
        XCTAssertEqual(result.matchedDestinations[0].type, .usdtPolygon)
    }

    func testAmountIsNotPartOfTheMatch() async throws {
        for amount in ["1", "50000000", "999999999999"] {
            client.getImpl = { _, _ in [Payment(destinations: [self.encrypted("cipher-usdt", id: "zk-usdt", type: .usdtPolygon)])] }
            aes.decryptImpl = { _, _ in self.usdtPolygonAddr }
            let result = try await service.verify(
                transferURI(.usdtPolygon, usdtPolygonAddr, encrypted: "enc-usdt", amount: amount)
            )
            XCTAssertEqual(result.status, .match, amount)
        }
    }

    func testPolygonUSDTCaseInsensitiveMatch() async throws {
        client.getImpl = { _, _ in [Payment(destinations: [self.encrypted("cipher-usdt", id: "zk-usdt", type: .usdtPolygon)])] }
        aes.decryptImpl = { _, _ in self.usdtPolygonAddr }
        let result = try await service.verify(
            transferURI(.usdtPolygon, usdtPolygonAddr.lowercased(), encrypted: "enc-usdt")
        )
        XCTAssertEqual(result.status, .match)
    }

    func testPolygonUSDT0xPrefixCaseInsensitiveMatch() async throws {
        client.getImpl = { _, _ in [Payment(destinations: [self.encrypted("cipher-usdt", id: "zk-usdt", type: .usdtPolygon)])] }
        aes.decryptImpl = { _, _ in self.usdtPolygonAddr }
        let mixed = "0X" + String(usdtPolygonAddr.dropFirst(2))
        let result = try await service.verify(transferURI(.usdtPolygon, mixed, encrypted: "enc-usdt"))
        XCTAssertEqual(result.status, .match)
    }

    func testPolygonUSDTSwappedIsTampered() async throws {
        client.getImpl = { _, _ in [Payment(destinations: [self.encrypted("cipher-usdt", id: "zk-usdt", type: .usdtPolygon)])] }
        aes.decryptImpl = { _, _ in self.usdtPolygonAddr }
        let result = try await service.verify(transferURI(.usdtPolygon, swappedEvmAddr, encrypted: "enc-usdt"))
        XCTAssertEqual(result.status, .tampered)
    }

    func testPolygonIgnoresSiblingBitcoinRail() async throws {
        client.getImpl = { _, _ in
            [Payment(destinations: [
                self.encrypted("cipher-btc", id: "zk-btc", type: .bitcoinAddress),
                self.encrypted("cipher-usdt", id: "zk-usdt", type: .usdtPolygon),
            ])]
        }
        aes.decryptImpl = { value, _ in
            value == "cipher-usdt" ? self.usdtPolygonAddr : self.addr
        }
        let result = try await service.verify(transferURI(.usdtPolygon, usdtPolygonAddr, encrypted: "enc-usdt"))
        XCTAssertEqual(result.status, .match)
        XCTAssertTrue(result.payments[0].destinations[0].isEncrypted)
        XCTAssertEqual(result.payments[0].destinations[0].type, .bitcoinAddress)
        XCTAssertFalse(result.payments[0].destinations[1].isEncrypted)
        XCTAssertEqual(result.payments[0].destinations[1].value, usdtPolygonAddr)
    }

    func testBitcoinIgnoresSiblingUsdtRail() async throws {
        client.getImpl = { _, _ in
            [Payment(destinations: [
                self.encrypted("cipher-btc", id: "zk-btc", type: .bitcoinAddress),
                self.encrypted("cipher-usdt", id: "zk-usdt", type: .usdtPolygon),
            ])]
        }
        aes.decryptImpl = { value, _ in
            value == "cipher-btc" ? self.addr : self.usdtPolygonAddr
        }
        let result = try await service.verify("bitcoin:\(addr)?branta_id=cipher-id&branta_secret=the-secret")
        XCTAssertEqual(result.status, .match)
        XCTAssertFalse(result.payments[0].destinations[0].isEncrypted)
        XCTAssertEqual(result.payments[0].destinations[0].value, addr)
        XCTAssertTrue(result.payments[0].destinations[1].isEncrypted)
        XCTAssertEqual(result.payments[0].destinations[1].type, .usdtPolygon)
    }

    func testPolygonSwappedStillTamperedWithSiblingBitcoin() async throws {
        client.getImpl = { _, _ in
            [Payment(destinations: [
                self.encrypted("cipher-btc", id: "zk-btc", type: .bitcoinAddress),
                self.encrypted("cipher-usdt", id: "zk-usdt", type: .usdtPolygon),
            ])]
        }
        aes.decryptImpl = { value, _ in
            value == "cipher-usdt" ? self.usdtPolygonAddr : self.addr
        }
        let result = try await service.verify(transferURI(.usdtPolygon, swappedEvmAddr, encrypted: "enc-usdt"))
        XCTAssertEqual(result.status, .tampered)
    }

    func testSecondUSDTDestinationWithAnotherAddressStaysEncrypted() async throws {
        client.getImpl = { _, _ in
            [Payment(destinations: [
                self.encrypted("cipher-sib", id: "zk-sib", type: .usdtPolygon),
                self.encrypted("cipher-usdt", id: "zk-usdt", type: .usdtPolygon),
            ])]
        }
        aes.decryptImpl = { value, _ in
            value == "cipher-sib" ? self.siblingUsdtAddr : self.usdtPolygonAddr
        }
        let result = try await service.verify(transferURI(.usdtPolygon, usdtPolygonAddr, encrypted: "enc-usdt"))
        XCTAssertEqual(result.status, .match)
        XCTAssertTrue(result.payments[0].destinations[0].isEncrypted)
        XCTAssertEqual(result.payments[0].destinations[0].value, "cipher-sib")
        XCTAssertFalse(result.payments[0].destinations[1].isEncrypted)
        XCTAssertEqual(result.payments[0].destinations[1].value, usdtPolygonAddr)
    }

    func testSwappedIsTamperedWhenNoDestinationOfTheTypeMatches() async throws {
        client.getImpl = { _, _ in
            [Payment(destinations: [
                self.encrypted("cipher-sib", id: "zk-sib", type: .usdtPolygon),
                self.encrypted("cipher-usdt", id: "zk-usdt", type: .usdtPolygon),
            ])]
        }
        aes.decryptImpl = { value, _ in
            value == "cipher-sib" ? self.siblingUsdtAddr : self.usdtPolygonAddr
        }
        let result = try await service.verify(transferURI(.usdtPolygon, swappedEvmAddr, encrypted: "enc-usdt"))
        XCTAssertEqual(result.status, .tampered)
    }

    func testPolygonUSDCMatchAndSwapped() async throws {
        client.getImpl = { _, _ in [Payment(destinations: [self.encrypted("cipher-usdc", id: "zk-usdc", type: .usdcPolygon)])] }
        aes.decryptImpl = { _, _ in self.usdcPolygonAddr }
        let match = try await service.verify(transferURI(.usdcPolygon, usdcPolygonAddr, encrypted: "enc-usdc"))
        XCTAssertEqual(match.status, .match)
        XCTAssertEqual(match.matchedDestinations[0].type, .usdcPolygon)
        let swapped = try await service.verify(transferURI(.usdcPolygon, swappedEvmAddr, encrypted: "enc-usdc"))
        XCTAssertEqual(swapped.status, .tampered)
    }

    func testScanBindsTheScannedTokenAndLeavesTheOtherEncrypted() async throws {
        let cases: [(scan: DestinationType, address: String, boundIndex: Int)] = [
            (.usdtPolygon, usdtPolygonAddr, 0),
            (.usdcPolygon, usdcPolygonAddr, 1),
        ]
        for testCase in cases {
            client.getImpl = { _, _ in
                [Payment(destinations: [
                    self.encrypted("cipher-usdt", id: "zk-usdt", type: .usdtPolygon),
                    self.encrypted("cipher-usdc", id: "zk-usdc", type: .usdcPolygon),
                ])]
            }
            aes.decryptImpl = { value, _ in
                value == "cipher-usdt" ? self.usdtPolygonAddr : self.usdcPolygonAddr
            }
            let result = try await service.verify(transferURI(testCase.scan, testCase.address, encrypted: "enc-scan"))
            XCTAssertEqual(result.status, .match, testCase.scan.rawValue)
            for (index, destination) in result.payments[0].destinations.enumerated() {
                XCTAssertEqual(destination.isEncrypted, index != testCase.boundIndex, testCase.scan.rawValue)
            }
        }
    }

    func testPolygonWrongSecretIsUnknown() async throws {
        client.getImpl = { _, _ in [Payment(destinations: [self.encrypted("cipher-usdt", id: "zk-usdt", type: .usdtPolygon)])] }
        aes.decryptImpl = { _, _ in throw AESError(message: "wrong key") }
        let result = try await service.verify(
            transferURI(.usdtPolygon, usdtPolygonAddr, encrypted: "enc-usdt", secret: "wrong-secret")
        )
        XCTAssertEqual(result.status, .unknown)
    }

    func testSameAddressUnderTwoTokensBindsOnlyTheScannedToken() async throws {
        for scan in [DestinationType.usdtPolygon, .usdcPolygon] {
            client.getImpl = { _, _ in
                [Payment(destinations: [
                    self.encrypted("cipher-usdt", id: "zk-usdt", type: .usdtPolygon),
                    self.encrypted("cipher-usdc", id: "zk-usdc", type: .usdcPolygon),
                ])]
            }
            aes.decryptImpl = { _, _ in self.usdtPolygonAddr }
            let result = try await service.verify(transferURI(scan, usdtPolygonAddr, encrypted: "enc-both"))
            XCTAssertEqual(result.status, .match, scan.rawValue)
            XCTAssertEqual(result.matchedDestinations.map(\.type), [scan], scan.rawValue)
        }
    }

    // MARK: Every EVM rail

    func testEveryEVMRailMatchesAndReturnsTheScannedType() async throws {
        for rail in evmTokenRails {
            let type = rail.type
            let address = deposit(for: type)
            client.gets.removeAll()
            client.getImpl = { _, _ in [Payment(destinations: [self.encrypted("cipher", id: "zk", type: type)])] }
            aes.decryptImpl = { _, _ in address }

            let result = try await service.verify(transferURI(type, address, encrypted: "enc-\(type.rawValue)"))
            XCTAssertEqual(result.status, .match, type.rawValue)
            XCTAssertEqual(client.gets, ["enc-\(type.rawValue)"], type.rawValue)
            XCTAssertEqual(result.matchedDestinations.map(\.type), [type], type.rawValue)
            XCTAssertEqual(result.matchedDestinations.map(\.value), [address], type.rawValue)

            let lower = try await service.verify(transferURI(type, address.lowercased(), encrypted: "enc"))
            XCTAssertEqual(lower.status, .match, type.rawValue)

            let tampered = try await service.verify(transferURI(type, swappedEvmAddr, encrypted: "enc"))
            XCTAssertEqual(tampered.status, .tampered, type.rawValue)
            XCTAssertTrue(tampered.matchedDestinations.isEmpty, type.rawValue)
        }
    }

    func testEveryEVMRailOnTheWrongChainOrWithoutBrantaParamsIsUnknownWithoutAGet() async throws {
        for rail in evmTokenRails {
            let address = deposit(for: rail.type)
            let wrongChain = try await service.verify(
                "ethereum:\(rail.contract)@999999/transfer?address=\(address)&branta_id=enc&branta_secret=the-secret"
            )
            XCTAssertEqual(wrongChain.status, .unknown, rail.type.rawValue)

            let noParams = try await service.verify(
                "ethereum:\(rail.contract)@\(rail.chainID)/transfer?address=\(address)&uint256=1000000"
            )
            XCTAssertEqual(noParams.status, .unknown, rail.type.rawValue)
        }
        XCTAssertTrue(client.gets.isEmpty)
    }

    func testEthereumScanIgnoresASiblingBitcoinRail() async throws {
        client.getImpl = { _, _ in
            [Payment(destinations: [
                self.encrypted("cipher-btc", id: "zk-btc", type: .bitcoinAddress),
                self.encrypted("cipher-usdt", id: "zk-usdt", type: .usdtEthereum),
            ])]
        }
        aes.decryptImpl = { value, _ in
            value == "cipher-usdt" ? self.usdtEthereumAddr : self.addr
        }
        let result = try await service.verify(transferURI(.usdtEthereum, usdtEthereumAddr, encrypted: "enc-usdt"))
        XCTAssertEqual(result.status, .match)
        XCTAssertTrue(result.payments[0].destinations[0].isEncrypted)
        XCTAssertEqual(result.matchedDestinations[0].type, .usdtEthereum)

        let swapped = try await service.verify(transferURI(.usdtEthereum, swappedEvmAddr, encrypted: "enc-usdt"))
        XCTAssertEqual(swapped.status, .tampered)
    }

    func testADualTokenPaymentBindsOnlyTheScannedToken() async throws {
        let dualToken = {
            Payment(destinations: [
                self.encrypted("cipher-usdt", id: "zk-usdt", type: .usdtEthereum),
                self.encrypted("cipher-usdc", id: "zk-usdc", type: .usdcEthereum),
            ])
        }
        aes.decryptImpl = { value, _ in
            value == "cipher-usdt" ? self.usdtEthereumAddr : self.usdcEthereumAddr
        }
        // Both scans send the USDT ciphertext as branta_id. Only the token named in the URI binds.
        client.getImpl = { _, _ in [dualToken()] }
        let usdt = try await service.verify(transferURI(.usdtEthereum, usdtEthereumAddr, encrypted: "enc-usdt"))
        XCTAssertEqual(usdt.status, .match)
        XCTAssertEqual(usdt.matchedDestinations.map(\.type), [.usdtEthereum])
        XCTAssertFalse(usdt.payments[0].destinations[0].isEncrypted)
        XCTAssertTrue(usdt.payments[0].destinations[1].isEncrypted)

        client.getImpl = { _, _ in [dualToken()] }
        let usdc = try await service.verify(transferURI(.usdcEthereum, usdcEthereumAddr, encrypted: "enc-usdt"))
        XCTAssertEqual(usdc.status, .match)
        XCTAssertEqual(usdc.matchedDestinations.map(\.type), [.usdcEthereum])
        XCTAssertTrue(usdc.payments[0].destinations[0].isEncrypted)
        XCTAssertFalse(usdc.payments[0].destinations[1].isEncrypted)

        client.getImpl = { _, _ in [dualToken()] }
        let swapped = try await service.verify(transferURI(.usdtEthereum, swappedEvmAddr, encrypted: "enc-usdt"))
        XCTAssertEqual(swapped.status, .tampered)
    }

    func testAUSDCScanAgainstAUSDTOnlyPaymentIsUnknown() async throws {
        client.getImpl = { _, _ in [Payment(destinations: [self.encrypted("cipher-usdt", id: "zk-usdt", type: .usdtEthereum)])] }
        aes.decryptImpl = { _, _ in self.usdtEthereumAddr }
        let result = try await service.verify(transferURI(.usdcEthereum, usdcEthereumAddr, encrypted: "enc-usdt"))
        XCTAssertEqual(result.status, .unknown)
        XCTAssertTrue(result.matchedDestinations.isEmpty)
    }

    func testAnEthereumScanDoesNotMatchAPolygonOnlyPayment() async throws {
        client.getImpl = { _, _ in
            [Payment(destinations: [self.encrypted("cipher-pol", id: "zk-pol", type: .usdtPolygon)])]
        }
        aes.decryptImpl = { _, _ in self.usdtPolygonAddr }
        let result = try await service.verify(transferURI(.usdtEthereum, usdtEthereumAddr, encrypted: "enc-chain"))
        XCTAssertEqual(result.status, .unknown)
        XCTAssertTrue(result.matchedDestinations.isEmpty)
    }

    func testAnEthereumScanLeavesAPolygonRailInTheSamePaymentEncrypted() async throws {
        client.getImpl = { _, _ in
            [Payment(destinations: [
                self.encrypted("cipher-pol", id: "zk-pol", type: .usdtPolygon),
                self.encrypted("cipher-eth", id: "zk-eth", type: .usdtEthereum),
            ])]
        }
        aes.decryptImpl = { value, _ in
            value == "cipher-pol" ? self.usdtPolygonAddr : self.usdtEthereumAddr
        }
        let result = try await service.verify(transferURI(.usdtEthereum, usdtEthereumAddr, encrypted: "enc-eth"))
        XCTAssertEqual(result.status, .match)
        XCTAssertTrue(result.payments[0].destinations[0].isEncrypted)
        XCTAssertFalse(result.payments[0].destinations[1].isEncrypted)
        XCTAssertEqual(result.matchedDestinations.count, 1)
    }

    // MARK: Forms that do not verify

    func testOtherFunctionsAreUnknownWithoutAGet() async throws {
        let rail = rail(for: .usdtBase)
        for function in ["approve", "transferFrom", "transfer;x=1"] {
            let result = try await service.verify(
                "ethereum:\(rail.contract)@\(rail.chainID)/\(function)?address=\(swappedEvmAddr)&uint256=1&branta_id=abc&branta_secret=the-secret"
            )
            XCTAssertEqual(result.status, .unknown, function)
        }
        XCTAssertTrue(client.gets.isEmpty)
    }

    func testTheAuthorityFormIsUnknownWithoutAGet() async throws {
        let rail = rail(for: .usdtBase)
        let result = try await service.verify(
            "ethereum://\(rail.contract)@\(rail.chainID)/transfer?address=\(swappedEvmAddr)&branta_id=abc&branta_secret=the-secret"
        )
        XCTAssertEqual(result.status, .unknown)
        XCTAssertTrue(client.gets.isEmpty)
    }

    func testUnparseableInputIsUnknownAndDoesNotThrow() async throws {
        let inputs = [
            "ethereum://[bad/transfer",
            "bitcoin://[bad",
            "ethereum:0xc2132d05d31c914a87c6611c10748aeb04b58e8f@" + String(repeating: "9", count: 5000)
                + "/transfer?address=" + swappedEvmAddr,
        ]
        for input in inputs {
            let result = try await service.verify(input)
            XCTAssertEqual(result.status, .unknown, String(input.prefix(40)))
        }
        XCTAssertTrue(client.gets.isEmpty)
    }

    func testRemovedSchemesAreUnknownWithoutAGetEvenWithValidParams() async throws {
        client.getImpl = { _, _ in [Payment(destinations: [self.encrypted("cipher-usdt", id: "zk-usdt", type: .usdtPolygon)])] }
        aes.decryptImpl = { _, _ in self.usdtPolygonAddr }
        for scheme in ["pol", "eth", "bsc", "tron", "ton", "sol"] {
            let result = try await service.verify(
                "\(scheme):\(usdtPolygonAddr)?value=50&branta_id=enc-usdt&branta_secret=the-secret"
            )
            XCTAssertEqual(result.status, .unknown, scheme)
        }
        XCTAssertTrue(client.gets.isEmpty)
    }

    func testBareChainAddressesAreUnknownWithoutAGet() async throws {
        for address in [usdtPolygonAddr, usdtEthereumAddr, usdtTronAddr, usdtTonAddr, usdcSolanaAddr] {
            let result = try await service.verify(address)
            XCTAssertEqual(result.status, .unknown, address)
        }
        XCTAssertTrue(client.gets.isEmpty)
    }

    // MARK: addPayment

    func testAddPaymentEncryptsSecretKeyRailsWithGeneratedSecret() async throws {
        let rails: [(String, DestinationType)] = [
            (usdtPolygonAddr, .usdtPolygon),
            (usdcPolygonAddr, .usdcPolygon),
            (usdtEthereumAddr, .usdtEthereum),
            (deposit(for: .usdtBsc), .usdtBsc),
            (deposit(for: .usdcBsc), .usdcBsc),
            (deposit(for: .usdtBase), .usdtBase),
            (deposit(for: .usdcBase), .usdcBase),
            (deposit(for: .usdtArbitrum), .usdtArbitrum),
            (deposit(for: .usdcArbitrum), .usdcArbitrum),
            (usdtTronAddr, .usdtTron),
            (usdtTonAddr, .usdtTon),
            (usdtSolanaAddr, .usdtSolana),
            (usdcSolanaAddr, .usdcSolana),
        ]
        for (address, type) in rails {
            client.posts.removeAll()
            service = BrantaService(
                options: BrantaApiOptions(environment: .localhost),
                client: client,
                aes: aes,
                secretGenerator: FakeSecrets(["rail-secret"])
            )
            let payment = Payment(destinations: [Destination(value: address, type: type, id: "zk-1")])
            let added = try await service.addPayment(payment)
            XCTAssertEqual(payment.destinations[0].value, address, type.rawValue)
            XCTAssertNotEqual(client.posts[0].destinations[0].value, address, type.rawValue)
            XCTAssertEqual(client.posts[0].destinations[0].type, type, type.rawValue)
            XCTAssertEqual(added.secret, "rail-secret", type.rawValue)
        }
    }

    func testAddPaymentBareOxWithoutTypeUnsupported() async {
        let payment = Payment(destinations: [Destination(value: usdtPolygonAddr)])
        do {
            _ = try await service.addPayment(payment)
            XCTFail("expected error")
        } catch let error as BrantaPaymentError {
            XCTAssertTrue(error.message.contains("cannot be encrypted"))
        } catch {
            XCTFail("\(error)")
        }
    }
}
