import XCTest
@testable import Branta

final class QRParserTests: XCTestCase {
    func testPlainBitcoin() {
        let parser = QRParser("1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa")
        XCTAssertEqual(parser.destination, "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa")
        XCTAssertEqual(parser.destinationType, .bitcoinAddress)
    }

    func testBech32AndTestnet() {
        XCTAssertEqual(QRParser("bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4").destinationType, .bitcoinAddress)
        XCTAssertEqual(QRParser("tb1qshra2mlujc9wfscvn4d8aqpyqgxzl55853xg7s").destinationType, .bitcoinAddress)
        XCTAssertEqual(QRParser("bcrt1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq").destinationType, .bitcoinAddress)
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

    func testDuplicateQueryKeyKeepsTheFirstValue() {
        let parser = QRParser("bitcoin:1attackeraddr?branta_id=ID1&branta_secret=SEC1&branta_secret=ATTACKER")
        XCTAssertEqual(parser.onChainEncryptionText, "ID1")
        XCTAssertEqual(parser.onChainEncryptionSecret, "SEC1")
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

    func testBip321BcAndTbAreOnChainAddresses() {
        let parser = QRParser("bitcoin:?bc=bc1qmerchant&tb=tb1qtest")
        XCTAssertEqual(parser.destinations.map(\.value), ["", "bc1qmerchant", "tb1qtest"])
        XCTAssertEqual(parser.destinations[1].type, .bitcoinAddress)
        XCTAssertEqual(parser.destinations[2].type, .bitcoinAddress)
        XCTAssertFalse(parser.hasUnverifiableInstruction)
    }

    func testSpParamAddsSilentPayment() {
        let parser = QRParser("bitcoin:bc1qmerchant?sp=sp1qqexample")
        XCTAssertEqual(parser.destinations[1].value, "sp1qqexample")
        XCTAssertEqual(parser.destinations[1].type, .silentPayment)
        XCTAssertFalse(parser.hasUnverifiableInstruction)
    }

    func testLnoAndPayAreUnverifiable() {
        let lno = QRParser("bitcoin:bc1qmerchant?lno=lno1qqexample")
        XCTAssertEqual(lno.destinations.count, 1)
        XCTAssertEqual(lno.destinations[0].value, "bc1qmerchant")
        XCTAssertTrue(lno.hasUnverifiableInstruction)

        let pay = QRParser("bitcoin:bc1qmerchant?pay=bitcoin:bc1qother")
        XCTAssertTrue(pay.hasUnverifiableInstruction)
        XCTAssertEqual(pay.destinations.map(\.value), ["bc1qmerchant"])
    }

    func testEmptyBolt12DoesNotFlagAndNonemptyDoes() {
        XCTAssertFalse(QRParser("bitcoin:bc1qmerchant?bolt12=").hasUnverifiableInstruction)
        XCTAssertTrue(QRParser("bitcoin:bc1qmerchant?bolt12=lno1qqexample").hasUnverifiableInstruction)
        XCTAssertFalse(QRParser("bitcoin:bc1qmerchant?lightning=").hasUnverifiableInstruction)
    }

    func testBolt12AndLNURLUrisAreUntyped() {
        XCTAssertNil(QRParser("lightning:lno1qqexample").destinationType)
        XCTAssertNil(QRParser("lightning:lnurl1qqexample").destinationType)
        XCTAssertTrue(QRParser("lightning:lno1qqexample").hasUnverifiableInstruction)
        XCTAssertTrue(QRParser("lightning:lnurl1qqexample").hasUnverifiableInstruction)
        XCTAssertEqual(QRParser("lightning:lnbc100n1ptest").destinationType, .bolt11)
        XCTAssertEqual(QRParser("LIGHTNING:lnbc100n1ptest").destinationType, .bolt11)
        XCTAssertFalse(QRParser("lno1plainTextNotUri").hasUnverifiableInstruction)
        XCTAssertNil(QRParser("LNURL1TESTVALUE").destinationType)
        XCTAssertNil(QRParser("0x" + String(repeating: "a", count: 40)).destinationType)
        XCTAssertNil(QRParser("user@example.com").destinationType)
    }

    func testPlainDerivedKeyTypes() {
        XCTAssertEqual(QRParser("lnbc100n1ptest").destinationType, .bolt11)
        XCTAssertEqual(QRParser("ark1testaddress").destinationType, .arkAddress)
        XCTAssertEqual(QRParser("tark1testaddress").destinationType, .arkAddress)
        XCTAssertEqual(QRParser("sp1testaddress").destinationType, .silentPayment)
        XCTAssertEqual(QRParser("tsp1testaddress").destinationType, .silentPayment)
    }

    func testControlCharactersAreStrippedBeforeTyping() {
        for prefix in ["bitcoi\tn:", "bitcoi\nn:", "bitcoi\rn:", "\u{01}bitcoin:"] {
            let parser = QRParser(prefix + "1attackeraddr?branta_id=ID1&branta_secret=SEC1")
            XCTAssertEqual(parser.destination, "1attackeraddr")
            XCTAssertEqual(parser.destinationType, .bitcoinAddress)
            XCTAssertTrue(parser.isOnChainZK())
            XCTAssertEqual(parser.onChainEncryptionText, "ID1")
            XCTAssertEqual(parser.onChainEncryptionSecret, "SEC1")
        }
        let tabbed = QRParser("bitcoin:1attac\tkeraddr?branta_id=ID1&branta_secret=SEC1")
        XCTAssertEqual(tabbed.destination, "1attackeraddr")
        XCTAssertEqual(QRParser("lightnin\tg:lnbc100n1ptest").destinationType, .bolt11)
    }

    func testPolUriIsSecretKeyWithoutTokenType() {
        let parser = QRParser("pol:0x278297528c32eCa01295B0d2135984d3442ec963?value=50&branta_id=enc&branta_secret=sec")
        XCTAssertEqual(parser.destination, "0x278297528c32eCa01295B0d2135984d3442ec963")
        XCTAssertNil(parser.destinationType)
        XCTAssertTrue(parser.destinations[0].secretKey)
        XCTAssertEqual(parser.onChainEncryptionText, "enc")
        XCTAssertEqual(parser.onChainEncryptionSecret, "sec")
        XCTAssertEqual(parser.expectedSecretKeyTypes, [.usdtPolygon, .usdcPolygon])
    }

    func testChainUriSchemesMapToTheirDestinationFamily() {
        let cases: [(String, [DestinationType])] = [
            ("eth", ethereumEvmDestinationTypes),
            ("bsc", bscEvmDestinationTypes),
            ("tron", tronDestinationTypes),
            ("ton", tonDestinationTypes),
            ("sol", solanaDestinationTypes),
        ]
        for (scheme, family) in cases {
            let parser = QRParser("\(scheme):someaddress?value=1&branta_id=enc&branta_secret=sec")
            XCTAssertEqual(parser.destination, "someaddress", scheme)
            XCTAssertNil(parser.destinationType, scheme)
            XCTAssertTrue(parser.destinations[0].secretKey, scheme)
            XCTAssertEqual(parser.expectedSecretKeyTypes, family, scheme)
            XCTAssertEqual(parser.onChainEncryptionText, "enc", scheme)
            XCTAssertEqual(parser.onChainEncryptionSecret, "sec", scheme)
        }
        XCTAssertEqual(ethereumEvmDestinationTypes, [.usdtEthereum, .usdcEthereum])
        XCTAssertEqual(tronDestinationTypes, [.usdtTron])
        XCTAssertEqual(Set(secretKeyURIFamilies.keys), ["pol", "eth", "bsc", "tron", "ton", "sol"])
    }

    func testIsSecretKeyAddressTypeCoversBitcoinAndEveryStableFamilyMember() {
        XCTAssertTrue(isSecretKeyAddressType(.bitcoinAddress))
        for family in secretKeyURIFamilies.values {
            for type in family {
                XCTAssertTrue(isSecretKeyAddressType(type), type.rawValue)
            }
        }
        XCTAssertFalse(isSecretKeyAddressType(.arkAddress))
        XCTAssertFalse(isSecretKeyAddressType(.silentPayment))
        XCTAssertEqual(DestinationType(rawValue: "usdt_tron"), .usdtTron)
        XCTAssertEqual(DestinationType(rawValue: "usdc_solana"), .usdcSolana)
    }

    func testBitcoinUriExpectsBitcoinSecretKeyFamily() {
        let parser = QRParser("bitcoin:bc1qmerchant?branta_id=enc&branta_secret=sec")
        XCTAssertTrue(parser.destinations[0].secretKey)
        XCTAssertEqual(parser.expectedSecretKeyTypes, [.bitcoinAddress])
    }

    func testPolygonEvmHelpers() {
        XCTAssertEqual(polygonEvmDestinationTypes, [.usdtPolygon, .usdcPolygon])
        XCTAssertTrue(isSecretKeyAddressType(.bitcoinAddress))
        XCTAssertFalse(isSecretKeyAddressType(.bolt11))
    }

    func testOnChainZKRequiresBothParams() {
        XCTAssertFalse(QRParser("bitcoin:addr").isOnChainZK())
        XCTAssertFalse(QRParser("bitcoin:addr?branta_id=enc").isOnChainZK())
    }

    func testTrim() {
        XCTAssertEqual(QRParser("  1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa  ").destination, "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa")
    }

    func testOtherSchemeStaysUntyped() {
        let parser = QRParser("http://example.com")
        XCTAssertEqual(parser.destination, "http://example.com")
        XCTAssertNil(parser.destinationType)
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
        XCTAssertNil(payment.destinations[0].id)
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
}

final class WireFormatTests: XCTestCase {
    func testDestinationWireAlwaysSendsZkTrue() throws {
        let destination = Destination(
            value: "abc",
            isPrimary: true,
            type: .bitcoinAddress,
            id: "zk-1",
            encryptedDek: "dek",
            isEncrypted: false
        )
        let object = try jsonObject(WireCoding.encode(Payment(destinations: [destination])))
        let first = try XCTUnwrap((object["destinations"] as? [[String: Any]])?.first)
        XCTAssertEqual(first["value"] as? String, "abc")
        XCTAssertEqual(first["primary"] as? Bool, true)
        XCTAssertEqual(first["zk"] as? Bool, true)
        XCTAssertEqual(first["type"] as? String, "bitcoin_address")
        XCTAssertEqual(first["zk_id"] as? String, "zk-1")
        XCTAssertEqual(first["encrypted_dek"] as? String, "dek")
        XCTAssertNil(first["is_encrypted"])
        XCTAssertNil(object["ttl"])
        XCTAssertNil(object["description"])
    }

    func testPaymentOmitsDescriptionParentAndPluginVersion() throws {
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
            isMetadataDecrypted: true
        )
        let object = try jsonObject(WireCoding.encode(payment))
        XCTAssertEqual(object["ttl"] as? Int, 600)
        XCTAssertNil(object["description"])
        XCTAssertNil(object["btc_pay_server_plugin_version"])
        XCTAssertEqual((object["child_platform"] as? [String: Any])?["name"] as? String, "Child")
        XCTAssertNil(object["parent_platform"])
        XCTAssertNil(object["is_metadata_decrypted"])
    }

    func testDecodeZkAndParentPlatform() throws {
        let encrypted = try WireCoding.decodePayment(Data(#"{"destinations":[{"value":"abc","zk":true,"zk_id":"ab12cd","type":"bolt12"}]}"#.utf8))
        XCTAssertTrue(encrypted.destinations[0].isEncrypted)
        XCTAssertEqual(encrypted.destinations[0].id, "ab12cd")
        XCTAssertNil(encrypted.destinations[0].type)

        let skipped = try WireCoding.decodePayment(Data(#"{"destinations":[{"value":"abc","zk":false}]}"#.utf8))
        XCTAssertFalse(skipped.destinations[0].isEncrypted)
        let missing = try WireCoding.decodePayment(Data(#"{"destinations":[{"value":"abc"}]}"#.utf8))
        XCTAssertFalse(missing.destinations[0].isEncrypted)

        let parent = try WireCoding.decodePayment(Data(#"{"destinations":[],"parent_platform":{"name":"Parent"}}"#.utf8))
        XCTAssertEqual(parent.parentPlatform?.name, "Parent")
    }

    func testUnsetEnvironmentUsesStagingAndEmptyKeyDoesNotOverride() {
        XCTAssertEqual(resolvedBaseURL(defaults: BrantaApiOptions(), override: nil), BrantaEnvironment.staging.url)
        let defaults = BrantaApiOptions(environment: .production, apiKey: "parent", hmacSecret: "parent-secret")
        let override = BrantaApiOptions(apiKey: "", hmacSecret: "")
        XCTAssertEqual(resolvedAPIKey(defaults: defaults, override: override), "parent")
        XCTAssertEqual(resolvedHMACSecret(defaults: defaults, override: override), "parent-secret")
        XCTAssertEqual(resolvedBaseURL(defaults: defaults, override: override), BrantaEnvironment.production.url)
        XCTAssertEqual(
            resolvedBaseURL(defaults: defaults, override: BrantaApiOptions(environment: .localhost)),
            BrantaEnvironment.localhost.url
        )
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
