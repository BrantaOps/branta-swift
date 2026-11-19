import XCTest
@testable import Branta

final class QRParserTests: XCTestCase {
    private let bitcoinAddress = "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"

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

    private let baseUSDCContract = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
    private let deposit = "0x1111111111111111111111111111111111111111"

    func testERC681TransferBindsTheDepositAndOneToken() {
        let parser = QRParser(
            "ethereum:\(baseUSDCContract)@8453/transfer?address=\(deposit)&uint256=1000000&branta_id=abc%2Bdef%3D&branta_secret=1234"
        )
        XCTAssertEqual(parser.destination, deposit)
        XCTAssertEqual(parser.destinationType, .usdcBase)
        XCTAssertEqual(parser.destinations.count, 1)
        XCTAssertTrue(parser.destinations[0].secretKey)
        XCTAssertEqual(parser.expectedSecretKeyTypes, [.usdcBase])
        XCTAssertEqual(parser.onChainEncryptionText, "abc+def=")
        XCTAssertEqual(parser.onChainEncryptionSecret, "1234")
    }

    func testEveryRailBindsTheDepositAndOneType() {
        for rail in evmTokenRails {
            let parser = QRParser(
                "ethereum:\(rail.contract)@\(rail.chainID)/transfer?address=\(deposit)&branta_id=a&branta_secret=b"
            )
            XCTAssertEqual(parser.destination, deposit, rail.type.rawValue)
            XCTAssertEqual(parser.destinationType, rail.type, rail.type.rawValue)
            XCTAssertEqual(parser.expectedSecretKeyTypes, [rail.type], rail.type.rawValue)
        }
    }

    func testERC681ContractMatchesCaseInsensitively() {
        let parser = QRParser("ethereum:\(baseUSDCContract.lowercased())@8453/transfer?address=\(deposit)")
        XCTAssertEqual(parser.destinationType, .usdcBase)
    }

    func testERC681Uint256IsNotPartOfTheBinding() {
        for amount in ["1", "50000000", "999999999999999999999"] {
            let parser = QRParser("ethereum:\(baseUSDCContract)@8453/transfer?address=\(deposit)&uint256=\(amount)")
            XCTAssertEqual(parser.destination, deposit, amount)
            XCTAssertEqual(parser.destinationType, .usdcBase, amount)
        }
    }

    func testERC681ToleratesOneLeadingSlashAndAnUpperCaseScheme() {
        XCTAssertEqual(
            QRParser("ethereum:/\(baseUSDCContract)@8453/transfer?address=\(deposit)").destinationType,
            .usdcBase
        )
        XCTAssertEqual(
            QRParser("ETHEREUM:\(baseUSDCContract)@8453/transfer?address=\(deposit)").destinationType,
            .usdcBase
        )
    }

    func testERC681AcceptsAnUpperCase0XDepositPrefix() {
        let parser = QRParser(
            "ethereum:\(baseUSDCContract)@8453/transfer?address=0X\(deposit.dropFirst(2))"
        )
        XCTAssertEqual(parser.destinationType, .usdcBase)
    }

    func testERC681FirstAddressParamWins() {
        let parser = QRParser(
            "ethereum:\(baseUSDCContract)@8453/transfer?address=\(deposit)&address=0x\(String(repeating: "f", count: 40))"
        )
        XCTAssertEqual(parser.destination, deposit)
    }

    func testERC681PercentEncodedAmpersandStaysInsideBrantaID() {
        let parser = QRParser(
            "ethereum:\(baseUSDCContract)@8453/transfer?address=\(deposit)&branta_id=a%26b&branta_secret=s"
        )
        XCTAssertEqual(parser.onChainEncryptionText, "a&b")
        XCTAssertEqual(parser.onChainEncryptionSecret, "s")
    }

    func testERC681ParamsInTheFragmentAreNotRead() {
        let parser = QRParser(
            "ethereum:\(baseUSDCContract)@8453/transfer?address=\(deposit)#&branta_id=abc&branta_secret=1234"
        )
        XCTAssertEqual(parser.destinationType, .usdcBase)
        XCTAssertEqual(parser.onChainEncryptionText, "")
    }

    func testERC681QueryAfterAFragmentIsNotRead() {
        let parser = QRParser(
            "ethereum:\(baseUSDCContract)@8453/transfer#x?address=\(deposit)&branta_id=a&branta_secret=b"
        )
        XCTAssertNil(parser.destinationType)
        XCTAssertEqual(parser.onChainEncryptionText, "")
        XCTAssertTrue(parser.expectedSecretKeyTypes.isEmpty)
    }

    func testERC681FragmentAfterTheQueryIsDropped() {
        let parser = QRParser(
            "ethereum:\(baseUSDCContract)@8453/transfer?address=\(deposit)&branta_id=a&branta_secret=b#address=0x2"
        )
        XCTAssertEqual(parser.destination, deposit)
        XCTAssertEqual(parser.onChainEncryptionText, "a")
        XCTAssertEqual(parser.onChainEncryptionSecret, "b")
    }

    func testBitcoinFragmentDoesNotBleedIntoTheLastParam() {
        let parser = QRParser("bitcoin:\(bitcoinAddress)?branta_id=a&branta_secret=b#frag")
        XCTAssertEqual(parser.onChainEncryptionSecret, "b")
        XCTAssertEqual(QRParser("bitcoin:\(bitcoinAddress)#x?branta_id=a&branta_secret=b").onChainEncryptionText, "")
    }

    func testERC681ChainIDBeyond15DigitsIsUntyped() {
        let parser = QRParser(
            "ethereum:\(baseUSDCContract)@\(String(repeating: "9", count: 5000))/transfer?address=\(deposit)"
        )
        XCTAssertNil(parser.destinationType)
    }

    func testERC681LeadingZeroChainIDStillSelectsTheRail() {
        let parser = QRParser(
            "ethereum:\(baseUSDCContract)@\(String(repeating: "0", count: 4500))8453/transfer?address=\(deposit)"
        )
        XCTAssertEqual(parser.destinationType, .usdcBase)
    }

    func testIncompleteERC681FormsDoNotBind() {
        let forms = [
            // No chain id.
            "ethereum:\(baseUSDCContract)/transfer?address=\(deposit)&branta_id=abc&branta_secret=1234",
            // Payment-request prefix and ENS-style forms.
            "ethereum:pay-\(baseUSDCContract)@8453/transfer?address=\(deposit)&branta_id=abc&branta_secret=1234",
            "ethereum:vitalik.eth@8453/transfer?address=\(deposit)&branta_id=abc&branta_secret=1234",
            // // makes the contract an authority, not a path.
            "ethereum://\(baseUSDCContract)@8453/transfer?address=\(deposit)&branta_id=abc&branta_secret=1234",
            // Only transfer is a payment. approve and transferFrom are not.
            "ethereum:\(baseUSDCContract)@8453/approve?address=\(deposit)&branta_id=abc&branta_secret=1234",
            "ethereum:\(baseUSDCContract)@8453/transferFrom?address=\(deposit)&branta_id=abc&branta_secret=1234",
            // Path parameters after the function name.
            "ethereum:\(baseUSDCContract)@8453/transfer;x=1?address=\(deposit)&branta_id=abc&branta_secret=1234",
            // Chain id forms that are not plain digits.
            "ethereum:\(baseUSDCContract)@0x2105/transfer?address=\(deposit)&branta_id=abc&branta_secret=1234",
            "ethereum:\(baseUSDCContract)@-8453/transfer?address=\(deposit)&branta_id=abc&branta_secret=1234",
            "ethereum:\(baseUSDCContract)@+8453/transfer?address=\(deposit)&branta_id=abc&branta_secret=1234",
            "ethereum:\(baseUSDCContract)@/transfer?address=\(deposit)&branta_id=abc&branta_secret=1234",
            // No address, a truncated address, or an ENS recipient.
            "ethereum:\(baseUSDCContract)@8453/transfer?branta_id=abc&branta_secret=1234",
            "ethereum:\(baseUSDCContract)@8453/transfer?address=0x1234&branta_id=abc&branta_secret=1234",
            "ethereum:\(baseUSDCContract)@8453/transfer?address=vitalik.eth&branta_id=abc&branta_secret=1234",
        ]
        for uri in forms {
            let parser = QRParser(uri)
            XCTAssertNil(parser.destinationType, uri)
            XCTAssertTrue(parser.expectedSecretKeyTypes.isEmpty, uri)
            XCTAssertEqual(parser.onChainEncryptionText, "", uri)
            XCTAssertFalse(parser.destinations[0].secretKey, uri)
        }
    }

    func testUnknownContractDoesNotBind() {
        let parser = QRParser(
            "ethereum:0x\(String(repeating: "2", count: 40))@8453/transfer?address=\(deposit)&branta_id=a&branta_secret=b"
        )
        XCTAssertNil(parser.destinationType)
        XCTAssertEqual(parser.onChainEncryptionText, "")
    }

    func testAContractOnTheWrongChainDoesNotBind() {
        let parser = QRParser(
            "ethereum:\(baseUSDCContract)@1/transfer?address=\(deposit)&branta_id=a&branta_secret=b"
        )
        XCTAssertNil(parser.destinationType)
        XCTAssertEqual(parser.onChainEncryptionText, "")
    }

    func testUnparseableAuthorityIsAnUntypedDestination() {
        let parser = QRParser("ethereum://[bad/transfer")
        XCTAssertNil(parser.destinationType)
        XCTAssertEqual(parser.destination, "ethereum://[bad/transfer")
        // Other schemes never throw either. They carry no Branta params, so nothing is bound.
        let bitcoin = QRParser("bitcoin://[bad")
        XCTAssertEqual(bitcoin.onChainEncryptionText, "")
        XCTAssertTrue(bitcoin.expectedSecretKeyTypes.isEmpty || bitcoin.expectedSecretKeyTypes == [.bitcoinAddress])
    }

    func testRemovedChainSchemesDoNotBind() {
        for scheme in ["pol", "eth", "bsc", "tron", "ton", "sol"] {
            let text = "\(scheme):0x278297528c32eCa01295B0d2135984d3442ec963?value=50&branta_id=abc&branta_secret=1234"
            let parser = QRParser(text)
            XCTAssertEqual(parser.destination, text, scheme)
            XCTAssertNil(parser.destinationType, scheme)
            XCTAssertFalse(parser.destinations[0].secretKey, scheme)
            XCTAssertTrue(parser.expectedSecretKeyTypes.isEmpty, scheme)
            XCTAssertFalse(parser.isOnChainZK(), scheme)
        }
    }

    func testEVMTokenRailsCoverFiveNetworksWithOneTypeEach() {
        XCTAssertEqual(Set(evmTokenRails.map(\.chainID)), [1, 137, 8453, 42161, 56])
        XCTAssertEqual(evmTokenRails.count, 10)
        XCTAssertEqual(Set(evmTokenRails.map(\.type)).count, 10)
        for rail in evmTokenRails {
            XCTAssertEqual(rail.contract, rail.contract.lowercased())
        }
    }

    func testEVMTokenTypeSelectsByChainIDAndContract() {
        XCTAssertEqual(evmTokenType(chainID: 8453, contract: baseUSDCContract), .usdcBase)
        XCTAssertEqual(evmTokenType(chainID: 8453, contract: baseUSDCContract.lowercased()), .usdcBase)
        // Same contract on the wrong chain is not a rail.
        XCTAssertNil(evmTokenType(chainID: 1, contract: baseUSDCContract))
        // Polygon bridged USDC.e is not the native USDC contract.
        XCTAssertNil(evmTokenType(chainID: 137, contract: "0x2791bca1f2de4661ed88a30c99a7a9449aa84174"))
        // Arbitrum Nova is not Arbitrum One.
        XCTAssertNil(evmTokenType(chainID: 42170, contract: "0xaf88d065e77c8cc2239327c5edb3a432268e5831"))
    }

    func testIsSecretKeyAddressTypeCoversBitcoinEVMRailsAndPostOnlyTypes() {
        XCTAssertTrue(isSecretKeyAddressType(.bitcoinAddress))
        for rail in evmTokenRails {
            XCTAssertTrue(isSecretKeyAddressType(rail.type), rail.type.rawValue)
        }
        // Tron, TON, and Solana still encrypt on addPayment. They have no verify URI.
        for type in [DestinationType.usdtTron, .usdtTon, .usdtSolana, .usdcSolana] {
            XCTAssertTrue(isSecretKeyAddressType(type), type.rawValue)
        }
        XCTAssertFalse(isSecretKeyAddressType(.bolt11))
        XCTAssertFalse(isSecretKeyAddressType(.arkAddress))
        XCTAssertFalse(isSecretKeyAddressType(.silentPayment))
    }

    func testDestinationTypeRawValuesIncludeBaseAndArbitrum() {
        XCTAssertEqual(DestinationType(rawValue: "usdt_tron"), .usdtTron)
        XCTAssertEqual(DestinationType(rawValue: "usdt_base"), .usdtBase)
        XCTAssertEqual(DestinationType(rawValue: "usdc_base"), .usdcBase)
        XCTAssertEqual(DestinationType(rawValue: "usdt_arbitrum"), .usdtArbitrum)
        XCTAssertEqual(DestinationType(rawValue: "usdc_arbitrum"), .usdcArbitrum)
        XCTAssertNil(DestinationType(rawValue: "usdc_ton"))
    }

    func testBitcoinUriExpectsTheBitcoinSecretKeyType() {
        let parser = QRParser("bitcoin:bc1qmerchant?branta_id=enc&branta_secret=sec")
        XCTAssertTrue(parser.destinations[0].secretKey)
        XCTAssertEqual(parser.expectedSecretKeyTypes, [.bitcoinAddress])
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
        var defaults = BrantaApiOptions(environment: .production, apiKey: "parent")
        defaults.hmacSecret = "parent-secret"
        var override = BrantaApiOptions(apiKey: "")
        override.hmacSecret = ""
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
