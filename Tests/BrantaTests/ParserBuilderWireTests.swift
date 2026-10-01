import XCTest
@testable import Branta

final class QRParserTests: XCTestCase {
    func testPlainBitcoin() {
        let parser = QRParser("1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa")
        XCTAssertEqual(parser.destination, "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa")
        XCTAssertEqual(parser.destinationType, .bitcoinAddress)
    }

    func testBech32() {
        XCTAssertEqual(QRParser("bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4").destinationType, .bitcoinAddress)
    }

    func testBitcoinURI() {
        let parser = QRParser("bitcoin:1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa")
        XCTAssertEqual(parser.destination, "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa")
        XCTAssertEqual(parser.destinationType, .bitcoinAddress)
    }

    func testBrantaParams() {
        let parser = QRParser("bitcoin:bc1qaddr?branta_id=encryptedId&branta_secret=mySecret")
        XCTAssertEqual(parser.onChainEncryptionText, "encryptedId")
        XCTAssertEqual(parser.onChainEncryptionSecret, "mySecret")
        XCTAssertTrue(parser.isOnChainZK())
    }

    func testEncodedBrantaID() {
        let parser = QRParser("bitcoin:addr?branta_id=abc%2Bdef%3D%3D&branta_secret=secret")
        XCTAssertEqual(parser.onChainEncryptionText, "abc+def==")
        XCTAssertEqual(parser.onChainEncryptionSecret, "secret")
    }

    func testLightningParam() {
        let parser = QRParser("bitcoin:addr?lightning=lnbc100n1ptest")
        XCTAssertEqual(parser.destinations.count, 2)
        XCTAssertEqual(parser.destinations[1].value, "lnbc100n1ptest")
        XCTAssertEqual(parser.destinations[1].type, .bolt11)
    }

    func testArkAndSilentParams() {
        let ark = QRParser("bitcoin:addr?ark=ark1testaddress")
        XCTAssertEqual(ark.destinations[1].type, .arkAddress)
        let silent = QRParser("bitcoin:addr?silent_payment=sp1testaddress")
        XCTAssertEqual(silent.destinations[1].type, .silentPayment)
    }

    func testLightningURI() {
        XCTAssertEqual(QRParser("lightning:lnbc100n1ptest").destinationType, .bolt11)
        XCTAssertEqual(QRParser("LIGHTNING:lnbc100n1ptest").destinationType, .bolt11)
    }

    func testPlainTypes() {
        XCTAssertEqual(QRParser("lnbc100n1ptest").destinationType, .bolt11)
        XCTAssertEqual(QRParser("LNURL1TESTVALUE").destinationType, .lnURL)
        XCTAssertEqual(QRParser("ark1testaddress").destinationType, .arkAddress)
        XCTAssertEqual(QRParser("sp1testaddress").destinationType, .silentPayment)
        XCTAssertEqual(QRParser("tsp1testaddress").destinationType, .silentPayment)
        XCTAssertEqual(QRParser("0x" + String(repeating: "a", count: 40)).destinationType, .tetherAddress)
        XCTAssertEqual(QRParser("T" + String(repeating: "a", count: 33)).destinationType, .tetherAddress)
        XCTAssertEqual(QRParser("user@example.com").destinationType, .lnAddress)
    }

    func testOnChainZKRequiresBothParams() {
        XCTAssertFalse(QRParser("bitcoin:addr").isOnChainZK())
        XCTAssertFalse(QRParser("bitcoin:addr?branta_id=enc").isOnChainZK())
    }

    func testTrim() {
        XCTAssertEqual(QRParser("  1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa  ").destination, "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa")
    }
}

final class PaymentBuilderTests: XCTestCase {
    func testAddDestination() {
        let payment = PaymentBuilder()
            .addDestination("1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa", type: .bitcoinAddress)
            .build()
        XCTAssertEqual(payment.destinations.count, 1)
        XCTAssertEqual(payment.destinations[0].value, "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa")
        XCTAssertEqual(payment.destinations[0].type, .bitcoinAddress)
        XCTAssertFalse(payment.destinations[0].isZk)
    }

    func testSetZK() {
        let payment = PaymentBuilder()
            .addDestination("addr1", type: .bitcoinAddress)
            .setZK()
            .addDestination("lnbc100n1ptest", type: .bolt11)
            .setZK()
            .build()
        XCTAssertTrue(payment.destinations[0].isZk)
        XCTAssertTrue(payment.destinations[1].isZk)
        XCTAssertNotEqual(payment.destinations[0].zkID, payment.destinations[1].zkID)
        XCTAssertEqual(payment.destinations[0].zkID, payment.destinations[0].zkID?.lowercased())
    }

    func testMetadataDescriptionTTLAndChild() {
        let payment = PaymentBuilder()
            .addDestination("addr", type: .bitcoinAddress)
            .setDescription("Test description")
            .addMetadata(key: "email", value: "test@example.com")
            .addMetadata(key: "name", value: "Alice")
            .setTTL(600)
            .setPlatformLogoURL("https://example.com/logo.png")
            .setChildPlatform(name: "ChildBrand", logoURL: "https://child.com/logo.png")
            .build()
        XCTAssertEqual(payment.description, "Test description")
        XCTAssertTrue(payment.metadata?.contains("email") == true)
        XCTAssertTrue(payment.metadata?.contains("test@example.com") == true)
        XCTAssertTrue(payment.metadata?.contains("name") == true)
        XCTAssertEqual(payment.ttl, 600)
        XCTAssertEqual(payment.platformLogoURL, "https://example.com/logo.png")
        XCTAssertEqual(payment.childPlatform?.name, "ChildBrand")
        XCTAssertEqual(payment.childPlatform?.logoURL, "https://child.com/logo.png")
    }

    func testSetZKWithNoDestinations() {
        XCTAssertTrue(PaymentBuilder().setZK().build().destinations.isEmpty)
    }
}

final class WireFormatTests: XCTestCase {
    func testDestinationWireNames() throws {
        let destination = Destination(
            value: "abc",
            isPrimary: true,
            isZk: true,
            type: .bitcoinAddress,
            zkID: "zk-1",
            encryptedDek: "dek",
            isEncrypted: true
        )
        let payment = Payment(destinations: [destination], ttl: 0)
        let object = try jsonObject(WireCoding.encode(payment))
        let destinations = object["destinations"] as? [[String: Any]]
        let first = try XCTUnwrap(destinations?.first)
        XCTAssertEqual(first["value"] as? String, "abc")
        XCTAssertEqual(first["primary"] as? Bool, true)
        XCTAssertEqual(first["zk"] as? Bool, true)
        XCTAssertEqual(first["type"] as? String, "bitcoin_address")
        XCTAssertEqual(first["zk_id"] as? String, "zk-1")
        XCTAssertEqual(first["encrypted_dek"] as? String, "dek")
        XCTAssertNil(first["is_encrypted"])
    }

    func testPaymentOmitsParentPlatformAndClientFlags() throws {
        let payment = Payment(
            description: "desc",
            destinations: [Destination(value: "abc")],
            createdAt: "2026-01-01T00:00:00Z",
            ttl: 600,
            metadata: "{}",
            platform: "Acme",
            platformLogoURL: "https://example.com/logo.png",
            parentPlatform: Platform(name: "Parent"),
            childPlatform: Platform(name: "Child"),
            btcPayServerPluginVersion: "1.0.0",
            isMetadataDecrypted: true
        )
        let object = try jsonObject(WireCoding.encode(payment))
        XCTAssertEqual(object["btc_pay_server_plugin_version"] as? String, "1.0.0")
        XCTAssertEqual((object["child_platform"] as? [String: Any])?["name"] as? String, "Child")
        XCTAssertNil(object["parent_platform"])
        XCTAssertNil(object["is_metadata_decrypted"])
    }

    func testDecodeParentPlatformAndZKID() throws {
        let json = #"{"destinations":[{"value":"abc","zk_id":"ab12cd"}],"parent_platform":{"name":"Parent"}}"#
        let payment = try WireCoding.decodePayment(Data(json.utf8))
        XCTAssertEqual(payment.parentPlatform?.name, "Parent")
        XCTAssertEqual(payment.destinations[0].zkID, "ab12cd")
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
