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
    private let swappedPolygonAddr = "0x1111111111111111111111111111111111111111"

    private func polURI(_ address: String, encrypted: String, secret: String) -> String {
        "pol:\(address)?value=50&user=send&currency=USD&branta_id=\(encrypted)&branta_secret=\(secret)"
    }

    func testPolUsdtMatchIgnoresAmountQuery() async throws {
        client.getImpl = { lookup, _ in
            XCTAssertEqual(lookup, "enc-usdt")
            return [Payment(destinations: [self.encrypted("cipher-usdt", id: "zk-usdt", type: .usdtPolygon)])]
        }
        aes.decryptImpl = { value, secret in
            XCTAssertEqual(value, "cipher-usdt")
            XCTAssertEqual(secret, "the-secret")
            return self.usdtPolygonAddr
        }
        let result = try await service.verify(polURI(usdtPolygonAddr, encrypted: "enc-usdt", secret: "the-secret"))
        XCTAssertEqual(result.status, .match)
        XCTAssertEqual(result.payments[0].destinations[0].type, .usdtPolygon)
        XCTAssertEqual(result.payments[0].destinations[0].value, usdtPolygonAddr)
        XCTAssertEqual(result.matchedDestinations.count, 1)
        XCTAssertEqual(result.matchedDestinations[0].type, .usdtPolygon)
    }

    func testPolUsdtCaseInsensitiveMatch() async throws {
        client.getImpl = { _, _ in [Payment(destinations: [self.encrypted("cipher-usdt", id: "zk-usdt", type: .usdtPolygon)])] }
        aes.decryptImpl = { _, _ in self.usdtPolygonAddr }
        let result = try await service.verify(polURI(usdtPolygonAddr.lowercased(), encrypted: "enc-usdt", secret: "the-secret"))
        XCTAssertEqual(result.status, .match)
    }

    func testPolUsdt0xPrefixCaseInsensitiveMatch() async throws {
        client.getImpl = { _, _ in [Payment(destinations: [self.encrypted("cipher-usdt", id: "zk-usdt", type: .usdtPolygon)])] }
        aes.decryptImpl = { _, _ in self.usdtPolygonAddr }
        let mixed = "0X" + String(usdtPolygonAddr.dropFirst(2))
        let result = try await service.verify(polURI(mixed, encrypted: "enc-usdt", secret: "the-secret"))
        XCTAssertEqual(result.status, .match)
    }

    func testPolUsdtSwappedIsTampered() async throws {
        client.getImpl = { _, _ in [Payment(destinations: [self.encrypted("cipher-usdt", id: "zk-usdt", type: .usdtPolygon)])] }
        aes.decryptImpl = { _, _ in self.usdtPolygonAddr }
        let result = try await service.verify(polURI(swappedPolygonAddr, encrypted: "enc-usdt", secret: "the-secret"))
        XCTAssertEqual(result.status, .tampered)
    }

    func testBareUsdtAddressIsUnknown() async throws {
        let result = try await service.verify(usdtPolygonAddr)
        XCTAssertEqual(result.status, .unknown)
        XCTAssertTrue(client.gets.isEmpty)
    }

    func testPolWithoutBrantaParamsIsUnknown() async throws {
        let result = try await service.verify("pol:\(usdtPolygonAddr)?value=50")
        XCTAssertEqual(result.status, .unknown)
        XCTAssertTrue(client.gets.isEmpty)
    }

    func testPolIgnoresSiblingBitcoinRail() async throws {
        client.getImpl = { _, _ in
            [Payment(destinations: [
                self.encrypted("cipher-btc", id: "zk-btc", type: .bitcoinAddress),
                self.encrypted("cipher-usdt", id: "zk-usdt", type: .usdtPolygon),
            ])]
        }
        aes.decryptImpl = { value, _ in
            value == "cipher-usdt" ? self.usdtPolygonAddr : self.addr
        }
        let result = try await service.verify(polURI(usdtPolygonAddr, encrypted: "enc-usdt", secret: "the-secret"))
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

    func testPolSwappedStillTamperedWithSiblingBitcoin() async throws {
        client.getImpl = { _, _ in
            [Payment(destinations: [
                self.encrypted("cipher-btc", id: "zk-btc", type: .bitcoinAddress),
                self.encrypted("cipher-usdt", id: "zk-usdt", type: .usdtPolygon),
            ])]
        }
        aes.decryptImpl = { value, _ in
            value == "cipher-usdt" ? self.usdtPolygonAddr : self.addr
        }
        let result = try await service.verify(polURI(swappedPolygonAddr, encrypted: "enc-usdt", secret: "the-secret"))
        XCTAssertEqual(result.status, .tampered)
    }

    func testPolMatchIfAnyDualUsdt() async throws {
        client.getImpl = { _, _ in
            [Payment(destinations: [
                self.encrypted("cipher-sib", id: "zk-sib", type: .usdtPolygon),
                self.encrypted("cipher-usdt", id: "zk-usdt", type: .usdtPolygon),
            ])]
        }
        aes.decryptImpl = { value, _ in
            value == "cipher-sib" ? self.siblingUsdtAddr : self.usdtPolygonAddr
        }
        let result = try await service.verify(polURI(usdtPolygonAddr, encrypted: "enc-usdt", secret: "the-secret"))
        XCTAssertEqual(result.status, .match)
        XCTAssertTrue(result.payments[0].destinations[0].isEncrypted)
        XCTAssertEqual(result.payments[0].destinations[0].value, "cipher-sib")
        XCTAssertFalse(result.payments[0].destinations[1].isEncrypted)
        XCTAssertEqual(result.payments[0].destinations[1].value, usdtPolygonAddr)
    }

    func testPolSwappedTamperedWhenNoPolygonFamilyRailMatches() async throws {
        client.getImpl = { _, _ in
            [Payment(destinations: [
                self.encrypted("cipher-sib", id: "zk-sib", type: .usdtPolygon),
                self.encrypted("cipher-usdt", id: "zk-usdt", type: .usdtPolygon),
            ])]
        }
        aes.decryptImpl = { value, _ in
            value == "cipher-sib" ? self.siblingUsdtAddr : self.usdtPolygonAddr
        }
        let result = try await service.verify(polURI(swappedPolygonAddr, encrypted: "enc-usdt", secret: "the-secret"))
        XCTAssertEqual(result.status, .tampered)
    }

    func testPolUsdcMatch() async throws {
        client.getImpl = { _, _ in [Payment(destinations: [self.encrypted("cipher-usdc", id: "zk-usdc", type: .usdcPolygon)])] }
        aes.decryptImpl = { _, _ in self.usdcPolygonAddr }
        let result = try await service.verify(polURI(usdcPolygonAddr, encrypted: "enc-usdc", secret: "the-secret"))
        XCTAssertEqual(result.status, .match)
        XCTAssertEqual(result.matchedDestinations[0].type, .usdcPolygon)
    }

    func testPolUsdcSwappedIsTampered() async throws {
        client.getImpl = { _, _ in [Payment(destinations: [self.encrypted("cipher-usdc", id: "zk-usdc", type: .usdcPolygon)])] }
        aes.decryptImpl = { _, _ in self.usdcPolygonAddr }
        let result = try await service.verify(polURI(swappedPolygonAddr, encrypted: "enc-usdc", secret: "the-secret"))
        XCTAssertEqual(result.status, .tampered)
    }

    func testPolBindsUsdtLeavesUsdcEncrypted() async throws {
        client.getImpl = { _, _ in
            [Payment(destinations: [
                self.encrypted("cipher-usdt", id: "zk-usdt", type: .usdtPolygon),
                self.encrypted("cipher-usdc", id: "zk-usdc", type: .usdcPolygon),
            ])]
        }
        aes.decryptImpl = { value, _ in
            value == "cipher-usdt" ? self.usdtPolygonAddr : self.usdcPolygonAddr
        }
        let result = try await service.verify(polURI(usdtPolygonAddr, encrypted: "enc-usdt", secret: "the-secret"))
        XCTAssertEqual(result.status, .match)
        XCTAssertFalse(result.payments[0].destinations[0].isEncrypted)
        XCTAssertEqual(result.payments[0].destinations[0].type, .usdtPolygon)
        XCTAssertTrue(result.payments[0].destinations[1].isEncrypted)
        XCTAssertEqual(result.payments[0].destinations[1].type, .usdcPolygon)
    }

    func testPolBindsUsdcLeavesUsdtEncrypted() async throws {
        client.getImpl = { _, _ in
            [Payment(destinations: [
                self.encrypted("cipher-usdt", id: "zk-usdt", type: .usdtPolygon),
                self.encrypted("cipher-usdc", id: "zk-usdc", type: .usdcPolygon),
            ])]
        }
        aes.decryptImpl = { value, _ in
            value == "cipher-usdt" ? self.usdtPolygonAddr : self.usdcPolygonAddr
        }
        let result = try await service.verify(polURI(usdcPolygonAddr, encrypted: "enc-usdc", secret: "the-secret"))
        XCTAssertEqual(result.status, .match)
        XCTAssertTrue(result.payments[0].destinations[0].isEncrypted)
        XCTAssertEqual(result.payments[0].destinations[0].type, .usdtPolygon)
        XCTAssertFalse(result.payments[0].destinations[1].isEncrypted)
        XCTAssertEqual(result.payments[0].destinations[1].type, .usdcPolygon)
    }

    func testPolWrongSecretIsUnknown() async throws {
        client.getImpl = { _, _ in [Payment(destinations: [self.encrypted("cipher-usdt", id: "zk-usdt", type: .usdtPolygon)])] }
        aes.decryptImpl = { _, _ in throw AESError(message: "wrong key") }
        let result = try await service.verify(polURI(usdtPolygonAddr, encrypted: "enc-usdt", secret: "wrong-secret"))
        XCTAssertEqual(result.status, .unknown)
    }

    func testSameAddressUsdtAndUsdcBothMatch() async throws {
        client.getImpl = { _, _ in
            [Payment(destinations: [
                self.encrypted("cipher-usdt", id: "zk-usdt", type: .usdtPolygon),
                self.encrypted("cipher-usdc", id: "zk-usdc", type: .usdcPolygon),
            ])]
        }
        aes.decryptImpl = { _, _ in self.usdtPolygonAddr }
        let result = try await service.verify(polURI(usdtPolygonAddr, encrypted: "enc-both", secret: "the-secret"))
        XCTAssertEqual(result.status, .match)
        XCTAssertEqual(result.matchedDestinations.count, 2)
    }

    private let usdtEthereumAddr = "0xBF5550253939187432Ef4dccE8089765d3DCb47f"
    private let usdcEthereumAddr = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
    private let usdtBscAddr = "0x55d398326f99059fF775485246999027B3197955"
    private let usdcBscAddr = "0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d"
    private let usdtTronAddr = "T9yD14Nj9j7xAB4dbGeiX9h8unkKHxuWwb"
    private let usdtTonAddr = "EQDtFpEwcFAEcRe5mLVh2N6C0y-_tur3BYOM93pEZPw390by"
    private let usdtSolanaAddr = "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB"
    private let usdcSolanaAddr = "7EqQdEULxWcraVx3mXKFjc84LhCkMGZCkRuDofycyinf"
    private let swappedEvmAddr = "0x1111111111111111111111111111111111111111"
    private let swappedSolanaAddr = "11111111111111111111111111111111"

    private func chainURI(_ scheme: String, _ address: String, encrypted: String, secret: String) -> String {
        "\(scheme):\(address)?value=50&branta_id=\(encrypted)&branta_secret=\(secret)"
    }

    private func assertChainMatch(_ scheme: String, address: String, type: DestinationType) async throws {
        client.getImpl = { lookup, _ in
            XCTAssertEqual(lookup, "enc-chain")
            return [Payment(destinations: [self.encrypted("cipher-chain", id: "zk-chain", type: type)])]
        }
        aes.decryptImpl = { value, secret in
            XCTAssertEqual(value, "cipher-chain")
            XCTAssertEqual(secret, "the-secret")
            return address
        }
        let result = try await service.verify(chainURI(scheme, address, encrypted: "enc-chain", secret: "the-secret"))
        XCTAssertEqual(result.status, .match)
        XCTAssertEqual(result.matchedDestinations.count, 1)
        XCTAssertEqual(result.matchedDestinations[0].type, type)
        XCTAssertEqual(result.matchedDestinations[0].value, address)
    }

    func testEthUsdtMatch() async throws {
        try await assertChainMatch("eth", address: usdtEthereumAddr, type: .usdtEthereum)
    }

    func testEthUsdtCaseInsensitiveMatch() async throws {
        client.getImpl = { _, _ in [Payment(destinations: [self.encrypted("cipher-chain", id: "zk-chain", type: .usdtEthereum)])] }
        aes.decryptImpl = { _, _ in self.usdtEthereumAddr }
        let result = try await service.verify(
            chainURI("eth", usdtEthereumAddr.lowercased(), encrypted: "enc-chain", secret: "the-secret")
        )
        XCTAssertEqual(result.status, .match)
    }

    func testEthUsdt0xPrefixCaseInsensitiveMatch() async throws {
        client.getImpl = { _, _ in [Payment(destinations: [self.encrypted("cipher-chain", id: "zk-chain", type: .usdtEthereum)])] }
        aes.decryptImpl = { _, _ in self.usdtEthereumAddr }
        let mixed = "0X" + String(usdtEthereumAddr.dropFirst(2))
        let result = try await service.verify(
            chainURI("eth", mixed, encrypted: "enc-chain", secret: "the-secret")
        )
        XCTAssertEqual(result.status, .match)
    }

    func testEthIgnoresSiblingBitcoinRail() async throws {
        client.getImpl = { _, _ in
            [Payment(destinations: [
                self.encrypted("cipher-btc", id: "zk-btc", type: .bitcoinAddress),
                self.encrypted("cipher-usdt", id: "zk-usdt", type: .usdtEthereum),
            ])]
        }
        aes.decryptImpl = { value, _ in
            value == "cipher-usdt" ? self.usdtEthereumAddr : self.addr
        }
        let result = try await service.verify(
            chainURI("eth", usdtEthereumAddr, encrypted: "enc-usdt", secret: "the-secret")
        )
        XCTAssertEqual(result.status, .match)
        XCTAssertTrue(result.payments[0].destinations[0].isEncrypted)
        XCTAssertEqual(result.matchedDestinations[0].type, .usdtEthereum)
    }

    func testEthSwappedStillTamperedWhenSiblingBitcoinPresent() async throws {
        client.getImpl = { _, _ in
            [Payment(destinations: [
                self.encrypted("cipher-btc", id: "zk-btc", type: .bitcoinAddress),
                self.encrypted("cipher-usdt", id: "zk-usdt", type: .usdtEthereum),
            ])]
        }
        aes.decryptImpl = { value, _ in
            value == "cipher-usdt" ? self.usdtEthereumAddr : self.addr
        }
        let result = try await service.verify(
            chainURI("eth", swappedEvmAddr, encrypted: "enc-usdt", secret: "the-secret")
        )
        XCTAssertEqual(result.status, .tampered)
    }

    func testBscUsdtMatch() async throws {
        try await assertChainMatch("bsc", address: usdtBscAddr, type: .usdtBsc)
    }

    func testBscIgnoresSiblingBitcoinRail() async throws {
        client.getImpl = { _, _ in
            [Payment(destinations: [
                self.encrypted("cipher-btc", id: "zk-btc", type: .bitcoinAddress),
                self.encrypted("cipher-usdt", id: "zk-usdt", type: .usdtBsc),
            ])]
        }
        aes.decryptImpl = { value, _ in
            value == "cipher-usdt" ? self.usdtBscAddr : self.addr
        }
        let result = try await service.verify(
            chainURI("bsc", usdtBscAddr, encrypted: "enc-usdt", secret: "the-secret")
        )
        XCTAssertEqual(result.status, .match)
        XCTAssertTrue(result.payments[0].destinations[0].isEncrypted)
        XCTAssertEqual(result.matchedDestinations[0].type, .usdtBsc)
    }

    func testBscSwappedStillTamperedWhenSiblingBitcoinPresent() async throws {
        client.getImpl = { _, _ in
            [Payment(destinations: [
                self.encrypted("cipher-btc", id: "zk-btc", type: .bitcoinAddress),
                self.encrypted("cipher-usdt", id: "zk-usdt", type: .usdtBsc),
            ])]
        }
        aes.decryptImpl = { value, _ in
            value == "cipher-usdt" ? self.usdtBscAddr : self.addr
        }
        let result = try await service.verify(
            chainURI("bsc", swappedEvmAddr, encrypted: "enc-usdt", secret: "the-secret")
        )
        XCTAssertEqual(result.status, .tampered)
    }

    func testTronUsdtMatch() async throws {
        try await assertChainMatch("tron", address: usdtTronAddr, type: .usdtTron)
    }

    func testTonUsdtMatch() async throws {
        try await assertChainMatch("ton", address: usdtTonAddr, type: .usdtTon)
    }

    func testSolUsdcMatch() async throws {
        try await assertChainMatch("sol", address: usdcSolanaAddr, type: .usdcSolana)
    }

    func testEthSwappedIsTampered() async throws {
        client.getImpl = { _, _ in [Payment(destinations: [self.encrypted("cipher-chain", id: "zk-chain", type: .usdtEthereum)])] }
        aes.decryptImpl = { _, _ in self.usdtEthereumAddr }
        let result = try await service.verify(
            chainURI("eth", swappedEvmAddr, encrypted: "enc-chain", secret: "the-secret")
        )
        XCTAssertEqual(result.status, .tampered)
    }

    func testTronSwappedIsTampered() async throws {
        client.getImpl = { _, _ in [Payment(destinations: [self.encrypted("cipher-chain", id: "zk-chain", type: .usdtTron)])] }
        aes.decryptImpl = { _, _ in self.usdtTronAddr }
        let result = try await service.verify(
            chainURI("tron", "TAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", encrypted: "enc-chain", secret: "the-secret")
        )
        XCTAssertEqual(result.status, .tampered)
    }

    func testEthBindsUsdtLeavesUsdcEncrypted() async throws {
        client.getImpl = { _, _ in
            [Payment(destinations: [
                self.encrypted("cipher-usdt", id: "zk-usdt", type: .usdtEthereum),
                self.encrypted("cipher-usdc", id: "zk-usdc", type: .usdcEthereum),
            ])]
        }
        aes.decryptImpl = { value, _ in
            value == "cipher-usdt" ? self.usdtEthereumAddr : self.usdcEthereumAddr
        }
        let result = try await service.verify(
            chainURI("eth", usdtEthereumAddr, encrypted: "enc-usdt", secret: "the-secret")
        )
        XCTAssertEqual(result.status, .match)
        XCTAssertEqual(result.matchedDestinations.count, 1)
        XCTAssertEqual(result.matchedDestinations[0].type, .usdtEthereum)
        XCTAssertFalse(result.payments[0].destinations[0].isEncrypted)
        XCTAssertTrue(result.payments[0].destinations[1].isEncrypted)
        XCTAssertEqual(result.payments[0].destinations[1].value, "cipher-usdc")
    }

    func testBscBindsUsdtLeavesUsdcEncrypted() async throws {
        client.getImpl = { _, _ in
            [Payment(destinations: [
                self.encrypted("cipher-usdt", id: "zk-usdt", type: .usdtBsc),
                self.encrypted("cipher-usdc", id: "zk-usdc", type: .usdcBsc),
            ])]
        }
        aes.decryptImpl = { value, _ in
            value == "cipher-usdt" ? self.usdtBscAddr : self.usdcBscAddr
        }
        let result = try await service.verify(
            chainURI("bsc", usdtBscAddr, encrypted: "enc-usdt", secret: "the-secret")
        )
        XCTAssertEqual(result.status, .match)
        XCTAssertEqual(result.matchedDestinations[0].type, .usdtBsc)
        XCTAssertFalse(result.payments[0].destinations[0].isEncrypted)
        XCTAssertTrue(result.payments[0].destinations[1].isEncrypted)
    }

    func testSolBindsUsdtLeavesUsdcEncrypted() async throws {
        client.getImpl = { _, _ in
            [Payment(destinations: [
                self.encrypted("cipher-usdt", id: "zk-usdt", type: .usdtSolana),
                self.encrypted("cipher-usdc", id: "zk-usdc", type: .usdcSolana),
            ])]
        }
        aes.decryptImpl = { value, _ in
            value == "cipher-usdt" ? self.usdtSolanaAddr : self.usdcSolanaAddr
        }
        let result = try await service.verify(
            chainURI("sol", usdtSolanaAddr, encrypted: "enc-usdt", secret: "the-secret")
        )
        XCTAssertEqual(result.status, .match)
        XCTAssertEqual(result.matchedDestinations[0].type, .usdtSolana)
        XCTAssertFalse(result.payments[0].destinations[0].isEncrypted)
        XCTAssertTrue(result.payments[0].destinations[1].isEncrypted)
    }

    func testEthUriWithPolygonOnlyPaymentIsUnknown() async throws {
        client.getImpl = { _, _ in
            [Payment(destinations: [self.encrypted("cipher-pol", id: "zk-pol", type: .usdtPolygon)])]
        }
        aes.decryptImpl = { _, _ in self.usdtPolygonAddr }
        let result = try await service.verify(
            chainURI("eth", usdtEthereumAddr, encrypted: "enc-chain", secret: "the-secret")
        )
        XCTAssertEqual(result.status, .unknown)
        XCTAssertTrue(result.matchedDestinations.isEmpty)
    }

    func testBareChainAddressesAndUrisWithoutBrantaParamsAreUnknown() async throws {
        let eth = try await service.verify(usdtEthereumAddr)
        let tron = try await service.verify(usdtTronAddr)
        let ton = try await service.verify(usdtTonAddr)
        let sol = try await service.verify(usdcSolanaAddr)
        let ethNoBranta = try await service.verify("eth:\(usdtEthereumAddr)?value=50")
        let tronNoBranta = try await service.verify("tron:\(usdtTronAddr)")
        XCTAssertEqual(eth.status, .unknown)
        XCTAssertEqual(tron.status, .unknown)
        XCTAssertEqual(ton.status, .unknown)
        XCTAssertEqual(sol.status, .unknown)
        XCTAssertEqual(ethNoBranta.status, .unknown)
        XCTAssertEqual(tronNoBranta.status, .unknown)
        XCTAssertTrue(client.gets.isEmpty)
    }

    func testSolSwappedIsTampered() async throws {
        client.getImpl = { _, _ in [Payment(destinations: [self.encrypted("cipher-chain", id: "zk-chain", type: .usdcSolana)])] }
        aes.decryptImpl = { _, _ in self.usdcSolanaAddr }
        let result = try await service.verify(
            chainURI("sol", swappedSolanaAddr, encrypted: "enc-chain", secret: "the-secret")
        )
        XCTAssertEqual(result.status, .tampered)
    }

    func testAddPaymentEncryptsSecretKeyRailsWithGeneratedSecret() async throws {
        let rails: [(String, DestinationType)] = [
            (usdtPolygonAddr, .usdtPolygon),
            (usdcPolygonAddr, .usdcPolygon),
            (usdtEthereumAddr, .usdtEthereum),
            (usdtBscAddr, .usdtBsc),
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
