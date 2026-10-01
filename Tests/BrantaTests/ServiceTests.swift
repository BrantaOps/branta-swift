import XCTest
@testable import Branta

final class FakeClient: BrantaClienting {
    var getImpl: (String, BrantaClientOptions?) async throws -> [Payment] = { _, _ in [] }
    var postImpl: (Payment, BrantaClientOptions?) async throws -> Payment? = { _, _ in nil }
    var keyImpl: (BrantaClientOptions?) async throws -> Bool = { _ in false }
    var gets: [(String, BrantaClientOptions?)] = []
    var posts: [Payment] = []
    var keyCalls: [BrantaClientOptions?] = []

    func getPayments(destinationValue: String, options: BrantaClientOptions?) async throws -> [Payment] {
        gets.append((destinationValue, options))
        return try await getImpl(destinationValue, options)
    }

    func postPayment(_ payment: Payment, options: BrantaClientOptions?) async throws -> Payment? {
        posts.append(payment)
        return try await postImpl(payment, options)
    }

    func isAPIKeyValid(options: BrantaClientOptions?) async throws -> Bool {
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

    func encrypt(value: String, secret: String, deterministicNonce: Bool) throws -> String {
        let call = EncryptCall(value: value, secret: secret, deterministic: deterministicNonce)
        encryptCalls.append(call)
        if let result = encryptMap[call] { return result }
        throw AESError(message: "unexpected encrypt \(value)")
    }

    func decrypt(encryptedValue: String, secret: String) throws -> String {
        let call = DecryptCall(value: encryptedValue, secret: secret)
        decryptCalls.append(call)
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
        let value = values[min(index, values.count - 1)]
        index += 1
        return value
    }
}

final class ServiceTests: XCTestCase {
    private let bitcoin = "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"
    private let encryptedBitcoin = "encrypted-bitcoin-address"
    private let secret = "test-secret"
    private let bolt11 = "lnbc100n1ptest"
    private let encryptedBolt11 = "encrypted-bolt11-value"
    private let decryptedBolt11 = "lnbc100n1pdecrypted"
    private let ark = "ark100testaddress"
    private let encryptedArk = "encrypted-ark-address"
    private let swapped = "1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2"
    private let bech32 = "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"
    private let encryptedBech32 = "encrypted-bech32-address"
    private let plainMetadata = #"{"email":"test@example.com"}"#
    private let encryptedMetadata = "encrypted-metadata-ciphertext"
    private let dek = "test-dek"
    private let encryptedDekBitcoin = "encrypted-dek-for-bitcoin"
    private let encryptedDekBolt11 = "encrypted-dek-for-bolt11"
    private let encryptedDekValue = "encrypted-dek-blob"
    private let decryptedDek = "decrypted-dek-value"
    private let decryptedMetadata = #"{"email":"alice@example.com"}"#
    private let encryptedMetadataBlob = "encrypted-metadata-blob"

    private var client: FakeClient!
    private var aes: FakeAES!
    private var loose: BrantaService!
    private var strict: BrantaService!
    private var bolt11Hash: String!
    private var arkHash: String!

    private var looseOptions: BrantaClientOptions {
        BrantaClientOptions(baseURL: .localhost, defaultAPIKey: "test-api-key", privacy: .loose)
    }

    override func setUp() {
        super.setUp()
        client = FakeClient()
        aes = FakeAES()
        bolt11Hash = normalizedHash(bolt11)
        arkHash = normalizedHash(ark)
        aes.decryptMap[.init(value: encryptedBitcoin, secret: secret)] = bitcoin
        aes.decryptMap[.init(value: encryptedBolt11, secret: bolt11Hash)] = decryptedBolt11
        aes.decryptMap[.init(value: encryptedArk, secret: arkHash)] = ark
        aes.encryptMap[.init(value: bolt11, secret: bolt11Hash, deterministic: true)] = encryptedBolt11
        aes.encryptMap[.init(value: bitcoin, secret: secret, deterministic: false)] = encryptedBitcoin
        aes.encryptMap[.init(value: ark, secret: arkHash, deterministic: true)] = encryptedArk
        let secrets = FakeSecrets([secret])
        loose = BrantaService(options: looseOptions, client: client, aes: aes, secretGenerator: secrets)
        strict = BrantaService(
            options: BrantaClientOptions(baseURL: .localhost, defaultAPIKey: "test-api-key", privacy: .strict),
            client: client,
            aes: aes,
            secretGenerator: FakeSecrets([secret])
        )
    }

    private func zkBitcoin() -> Payment {
        PaymentBuilder().addDestination(encryptedBitcoin, type: .bitcoinAddress).setZK().build()
    }

    private func plainBitcoin() -> Payment {
        PaymentBuilder().addDestination(bitcoin, type: .bitcoinAddress).build()
    }

    func testQRZKBitcoinDecrypts() async throws {
        client.getImpl = { _, _ in [self.zkBitcoin()] }
        let result = try await loose.getPaymentsByQRCode("bitcoin:\(bitcoin)?branta_id=\(encryptedBitcoin)&branta_secret=\(secret)")
        XCTAssertEqual(client.gets.map(\.0), [encryptedBitcoin])
        XCTAssertEqual(result.payments[0].destinations[0].value, bitcoin)
    }

    func testQRPlainBitcoinLooksUpAddress() async throws {
        client.getImpl = { _, _ in [self.plainBitcoin()] }
        let result = try await loose.getPaymentsByQRCode("bitcoin:\(bitcoin)")
        XCTAssertEqual(client.gets.map(\.0), [bitcoin])
        XCTAssertEqual(result.payments.count, 1)
    }

    func testQRLightningUsesEncryptedLookup() async throws {
        client.getImpl = { _, _ in [PaymentBuilder().addDestination(self.bolt11, type: .bolt11).build()] }
        _ = try await loose.getPaymentsByQRCode("lightning:\(bolt11)")
        _ = try await loose.getPaymentsByQRCode("lightning:\(bolt11.uppercased())")
        XCTAssertEqual(client.gets.map(\.0), [encryptedBolt11, encryptedBolt11])
    }

    func testQRBolt11LeavesUnrelatedBitcoinEncrypted() async throws {
        let payment = PaymentBuilder()
            .addDestination(encryptedBolt11, type: .bolt11).setZK()
            .addDestination(encryptedBitcoin, type: .bitcoinAddress).setZK()
            .build()
        client.getImpl = { _, _ in [payment] }
        let result = try await loose.getPaymentsByQRCode("lightning:\(bolt11)")
        XCTAssertEqual(result.payments[0].destinations[0].value, decryptedBolt11)
        XCTAssertFalse(result.payments[0].destinations[0].isEncrypted)
        XCTAssertEqual(result.payments[0].destinations[1].value, encryptedBitcoin)
        XCTAssertTrue(result.payments[0].destinations[1].isEncrypted)
    }

    func testCombinedZKQRDecryptsAll() async throws {
        let payment = PaymentBuilder()
            .addDestination(encryptedBitcoin, type: .bitcoinAddress).setZK()
            .addDestination(encryptedBolt11, type: .bolt11).setZK()
            .addDestination(encryptedArk, type: .arkAddress).setZK()
            .build()
        client.getImpl = { _, _ in [payment] }
        let qr = "bitcoin:\(bitcoin)?branta_id=\(encryptedBitcoin)&branta_secret=\(secret)&lightning=\(bolt11)&ark=\(ark)"
        let result = try await loose.getPaymentsByQRCode(qr)
        let ids = payment.destinations.map(\.zkID)
        XCTAssertTrue(result.verifyURL.contains("k-\(ids[0]!)=\(secret)"))
        XCTAssertTrue(result.verifyURL.contains("k-\(ids[1]!)=\(bolt11Hash!)"))
        XCTAssertTrue(result.verifyURL.contains("k-\(ids[2]!)=\(arkHash!)"))
        XCTAssertEqual(result.payments[0].destinations[0].value, bitcoin)
        XCTAssertEqual(result.payments[0].destinations[1].value, decryptedBolt11)
    }

    func testSwappedAddressRejects() async {
        client.getImpl = { _, _ in [self.zkBitcoin()] }
        let qr = "bitcoin:\(swapped)?branta_id=\(encryptedBitcoin)&branta_secret=\(secret)"
        do {
            _ = try await loose.getPaymentsByQRCode(qr)
            XCTFail("expected tamper")
        } catch let error as BrantaPaymentError {
            XCTAssertEqual(error.reason, .tampered)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testBech32CaseMatchesAndBase58DoesNot() async throws {
        aes.decryptMap[.init(value: encryptedBech32, secret: secret)] = bech32
        let bech32Payment = PaymentBuilder().addDestination(encryptedBech32, type: .bitcoinAddress).setZK().build()
        client.getImpl = { value, _ in
            value == self.encryptedBech32 ? [bech32Payment] : [self.zkBitcoin()]
        }
        let upper = try await loose.getPaymentsByQRCode("bitcoin:\(bech32.uppercased())?branta_id=\(encryptedBech32)&branta_secret=\(secret)")
        XCTAssertEqual(upper.payments[0].destinations[0].value, bech32)

        do {
            _ = try await loose.getPaymentsByQRCode("bitcoin:\(bitcoin.lowercased())?branta_id=\(encryptedBitcoin)&branta_secret=\(secret)")
            XCTFail("expected tamper")
        } catch let error as BrantaPaymentError {
            XCTAssertEqual(error.reason, .tampered)
        }
    }

    func testLightningQRWithZKParamsSkipsAddressComparison() async throws {
        client.getImpl = { _, _ in [self.zkBitcoin()] }
        let qr = "lightning:\(bolt11)?branta_id=\(encryptedBitcoin)&branta_secret=\(secret)"
        let result = try await loose.getPaymentsByQRCode(qr)
        XCTAssertEqual(result.payments[0].destinations[0].value, bitcoin)
    }

    func testGetPaymentsPlainAndEmptyVerifyURL() async throws {
        client.getImpl = { _, _ in [self.plainBitcoin()] }
        let result = try await loose.getPayments(bitcoin)
        XCTAssertEqual(result.payments[0].destinations[0].value, bitcoin)
        XCTAssertEqual(result.verifyURL, "http://localhost:3000/v2/verify/\(bitcoin)")

        client.getImpl = { _, _ in [] }
        let empty = try await loose.getPayments(bitcoin)
        XCTAssertTrue(empty.payments.isEmpty)
        XCTAssertEqual(empty.verifyURL, "http://localhost:3000/v2/verify/\(bitcoin)")
    }

    func testGetPaymentsForwardsOptions() async throws {
        client.getImpl = { _, _ in [self.plainBitcoin()] }
        _ = try await loose.getPayments(bitcoin, options: looseOptions)
        XCTAssertEqual(client.gets.last?.1, looseOptions)
    }

    func testZKBitcoinDecryptRequiresTheRightKey() async throws {
        client.getImpl = { _, _ in [self.zkBitcoin()] }
        let decrypted = try await loose.getPayments(encryptedBitcoin, destinationEncryptionKey: secret)
        XCTAssertEqual(decrypted.payments[0].destinations[0].value, bitcoin)
        XCTAssertTrue(decrypted.verifyURL.contains("#k-"))

        aes.decryptCalls.removeAll()
        let missing = try await loose.getPayments(encryptedBitcoin, destinationEncryptionKey: nil)
        XCTAssertEqual(missing.payments[0].destinations[0].value, encryptedBitcoin)
        XCTAssertTrue(missing.payments[0].destinations[0].isEncrypted)
        XCTAssertTrue(aes.decryptCalls.isEmpty)

        let wrong = try await loose.getPayments(encryptedBitcoin, destinationEncryptionKey: "wrong-key")
        XCTAssertEqual(wrong.payments[0].destinations[0].value, encryptedBitcoin)
        XCTAssertTrue(wrong.payments[0].destinations[0].isEncrypted)
    }

    func testPlainDestinationDoesNotDecrypt() async throws {
        client.getImpl = { _, _ in [self.plainBitcoin()] }
        aes.decryptCalls.removeAll()
        _ = try await loose.getPayments(bitcoin, destinationEncryptionKey: secret)
        XCTAssertTrue(aes.decryptCalls.isEmpty)
    }

    func testBolt11HashLookupAndLooseFallback() async throws {
        client.getImpl = { value, _ in
            value == self.encryptedBolt11
                ? [PaymentBuilder().addDestination(self.encryptedBolt11, type: .bolt11).setZK().build()]
                : []
        }
        let result = try await loose.getPayments(bolt11)
        XCTAssertEqual(result.payments[0].destinations[0].value, decryptedBolt11)
        XCTAssertEqual(client.gets.map(\.0), [encryptedBolt11])

        client.gets.removeAll()
        client.getImpl = { _, _ in [] }
        let missing = try await loose.getPayments(bolt11)
        XCTAssertEqual(missing.verifyURL, "http://localhost:3000/v2/verify/\(bolt11)")
        XCTAssertEqual(client.gets.map(\.0), [encryptedBolt11, bolt11])
    }

    func testAddPaymentEncryptsZKBitcoinAndBolt11() async throws {
        let bitcoinPayment = PaymentBuilder().addDestination(bitcoin, type: .bitcoinAddress).setZK().build()
        let zkID = bitcoinPayment.destinations[0].zkID
        client.postImpl = { _, _ in
            Payment(destinations: [Destination(value: self.encryptedBitcoin, isZk: true, type: .bitcoinAddress, zkID: zkID)])
        }
        let added = try await loose.addPayment(bitcoinPayment)
        XCTAssertEqual(added.secret, secret)
        XCTAssertEqual(bitcoinPayment.destinations[0].value, encryptedBitcoin)
        XCTAssertEqual(added.verifyURL, "http://localhost:3000/v2/verify/\(encryptedBitcoin)#k-\(zkID!)=\(secret)")

        let invoice = PaymentBuilder().addDestination(bolt11, type: .bolt11).setZK().build()
        client.postImpl = { _, _ in
            Payment(destinations: [Destination(value: self.encryptedBolt11, isZk: true, type: .bolt11, zkID: invoice.destinations[0].zkID)])
        }
        _ = try await loose.addPayment(invoice)
        XCTAssertTrue(aes.encryptCalls.contains(.init(value: bolt11, secret: bolt11Hash, deterministic: true)))
        XCTAssertEqual(invoice.destinations[0].value, encryptedBolt11)
    }

    func testAddPaymentPlainDoesNotEncryptAndUnsupportedZKThrows() async throws {
        let plain = plainBitcoin()
        client.postImpl = { payment, _ in payment }
        aes.encryptCalls.removeAll()
        _ = try await loose.addPayment(plain)
        XCTAssertTrue(aes.encryptCalls.isEmpty)

        client.posts.removeAll()
        let tether = PaymentBuilder().addDestination("0xdeadbeef", type: .tetherAddress).setZK().build()
        do {
            _ = try await loose.addPayment(tether)
            XCTFail("expected throw")
        } catch is BrantaPaymentError {
            XCTAssertTrue(client.posts.isEmpty)
        }
    }

    func testAPIKeyValidForwardsOptions() async throws {
        client.keyImpl = { _ in true }
        let valid = try await loose.isAPIKeyValid(options: looseOptions)
        XCTAssertTrue(valid)
        XCTAssertEqual(client.keyCalls.last ?? nil, looseOptions as BrantaClientOptions?)
    }

    func testStrictMode() async throws {
        do {
            _ = try await strict.getPayments(bitcoin)
            XCTFail("expected throw")
        } catch is BrantaPaymentError {}
        XCTAssertTrue(client.gets.isEmpty)

        client.getImpl = { _, _ in [self.zkBitcoin()] }
        let decrypted = try await strict.getPayments(encryptedBitcoin, destinationEncryptionKey: secret)
        XCTAssertEqual(decrypted.payments[0].destinations[0].value, bitcoin)
        XCTAssertFalse(decrypted.payments[0].destinations[0].isEncrypted)

        client.gets.removeAll()
        client.getImpl = { value, _ in value == self.encryptedBolt11 ? [] : [self.plainBitcoin()] }
        let fallback = try await strict.getPayments(bolt11)
        XCTAssertTrue(fallback.payments.isEmpty)
        XCTAssertEqual(fallback.verifyURL, "http://localhost:3000/v2/verify/\(encryptedBolt11)")
        XCTAssertEqual(client.gets.map(\.0), [encryptedBolt11])

        let emptyQR = try await strict.getPaymentsByQRCode("bitcoin:\(bitcoin)")
        XCTAssertTrue(emptyQR.payments.isEmpty)
        XCTAssertEqual(emptyQR.verifyURL, "http://localhost:3000/v2/verify/\(bitcoin)")

        do {
            _ = try await strict.addPayment(plainBitcoin())
            XCTFail("expected throw")
        } catch is BrantaPaymentError {}

        let mixed = PaymentBuilder()
            .addDestination(bitcoin, type: .bitcoinAddress).setZK()
            .addDestination(bolt11, type: .bolt11)
            .build()
        do {
            _ = try await strict.addPayment(mixed)
            XCTFail("expected throw")
        } catch is BrantaPaymentError {}

        let zk = PaymentBuilder().addDestination(bitcoin, type: .bitcoinAddress).setZK().build()
        client.postImpl = { _, _ in
            Payment(destinations: [Destination(value: self.encryptedBitcoin, isZk: true, zkID: zk.destinations[0].zkID)])
        }
        _ = try await strict.addPayment(zk)
        XCTAssertEqual(client.posts.count, 1)
    }

    func testMetadataEnvelope() async throws {
        let aes2 = FakeAES()
        aes2.encryptMap[.init(value: plainMetadata, secret: dek, deterministic: false)] = encryptedMetadata
        aes2.encryptMap[.init(value: dek, secret: secret, deterministic: false)] = encryptedDekBitcoin
        aes2.encryptMap[.init(value: bitcoin, secret: secret, deterministic: false)] = encryptedBitcoin
        let service = BrantaService(
            options: looseOptions,
            client: client,
            aes: aes2,
            secretGenerator: FakeSecrets([dek, secret])
        )
        let payment = PaymentBuilder().addDestination(bitcoin, type: .bitcoinAddress).setZK().build()
        payment.metadata = plainMetadata
        client.postImpl = { _, _ in Payment(destinations: [Destination(value: self.encryptedBitcoin, isZk: true)]) }
        _ = try await service.addPayment(payment)
        XCTAssertEqual(payment.metadata, encryptedMetadata)
        XCTAssertEqual(payment.destinations[0].encryptedDek, encryptedDekBitcoin)

        let aes3 = FakeAES()
        aes3.encryptMap[.init(value: plainMetadata, secret: dek, deterministic: false)] = encryptedMetadata
        aes3.encryptMap[.init(value: dek, secret: bolt11Hash, deterministic: false)] = encryptedDekBolt11
        aes3.encryptMap[.init(value: bolt11, secret: bolt11Hash, deterministic: true)] = encryptedBolt11
        let boltService = BrantaService(options: looseOptions, client: client, aes: aes3, secretGenerator: FakeSecrets([dek, secret]))
        let invoice = PaymentBuilder().addDestination(bolt11, type: .bolt11).setZK().build()
        invoice.metadata = plainMetadata
        client.postImpl = { _, _ in Payment(destinations: [Destination(value: self.encryptedBolt11, isZk: true)]) }
        _ = try await boltService.addPayment(invoice)
        XCTAssertEqual(invoice.destinations[0].encryptedDek, encryptedDekBolt11)

        let plain = plainBitcoin()
        plain.metadata = plainMetadata
        client.postImpl = { payment, _ in payment }
        aes.encryptCalls.removeAll()
        _ = try await loose.addPayment(plain)
        XCTAssertEqual(plain.metadata, plainMetadata)
        XCTAssertNil(plain.destinations[0].encryptedDek)
    }

    func testMetadataDecryptsOnce() async throws {
        aes.decryptMap[.init(value: encryptedDekValue, secret: bolt11Hash)] = decryptedDek
        aes.decryptMap[.init(value: encryptedMetadataBlob, secret: decryptedDek)] = decryptedMetadata
        let payment = Payment(
            destinations: [
                Destination(value: encryptedBolt11, isZk: true, type: .bolt11, zkID: "zk1", encryptedDek: encryptedDekValue),
                Destination(value: encryptedArk, isZk: true, type: .arkAddress, zkID: "zk2", encryptedDek: "another-dek"),
            ],
            metadata: encryptedMetadataBlob
        )
        client.getImpl = { _, _ in [payment] }
        let result = try await loose.getPayments(bolt11)
        XCTAssertEqual(result.payments[0].metadata, decryptedMetadata)
        XCTAssertTrue(result.payments[0].isMetadataDecrypted)
        XCTAssertEqual(aes.decryptCalls.filter { $0.value == encryptedMetadataBlob }.count, 1)

        let untouched = Payment(
            destinations: [Destination(value: encryptedBolt11, isZk: true, type: .bolt11, zkID: "zk1")],
            metadata: encryptedMetadataBlob
        )
        client.getImpl = { _, _ in [untouched] }
        let left = try await loose.getPayments(bolt11)
        XCTAssertEqual(left.payments[0].metadata, encryptedMetadataBlob)
        XCTAssertFalse(left.payments[0].isMetadataDecrypted)
    }
}
