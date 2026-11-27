import XCTest
@testable import Branta

// Deprecated names are exercised only through these wrappers so the build stays warning-free.
@available(*, deprecated)
private func legacyBuilderSetChildPlatform(_ builder: PaymentBuilder, name: String, logoURL: String?, logoLightURL: String?) -> PaymentBuilder {
    builder.setChildPlatform(name: name, logoURL: logoURL, logoLightURL: logoLightURL)
}

@available(*, deprecated)
private func legacyPayment(childPlatform: Platform?, brand: Platform? = nil) -> Payment {
    Payment(destinations: [Destination(value: "abc")], brand: brand, childPlatform: childPlatform)
}

@available(*, deprecated)
private func legacyChildPlatform(of payment: Payment) -> Platform? {
    payment.childPlatform
}

@available(*, deprecated)
private func setLegacyChildPlatform(_ payment: inout Payment, _ platform: Platform?) {
    payment.childPlatform = platform
}

private func wireObject(_ payment: Payment) throws -> [String: Any] {
    let data = try WireCoding.encode(payment)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func brandBody(_ object: [String: Any]) -> [String: String]? {
    (object["brand"] as? [String: Any])?.compactMapValues { $0 as? String }
}

final class BrandTests: XCTestCase {
    private let expected = [
        "name": "Acme",
        "logo_url": "https://example.com/a.png",
        "logo_light_url": "https://example.com/a-light.png",
    ]

    func testSetBrandSendsBrandAndNoChildPlatform() throws {
        let payment = PaymentBuilder()
            .addDestination("addr", type: .bitcoinAddress)
            .setBrand(name: "Acme", logoURL: "https://example.com/a.png", logoLightURL: "https://example.com/a-light.png")
            .build()
        XCTAssertEqual(payment.brand?.name, "Acme")
        let object = try wireObject(payment)
        XCTAssertEqual(brandBody(object), expected)
        XCTAssertNil(object["child_platform"])
    }

    func testSetBrandOmitsNilLogos() throws {
        let payment = PaymentBuilder().addDestination("addr").setBrand(name: "Acme").build()
        let object = try wireObject(payment)
        XCTAssertEqual(brandBody(object), ["name": "Acme"])
    }

    @available(*, deprecated)
    func testSetChildPlatformProducesIdenticalBrandBody() throws {
        let builder = PaymentBuilder().addDestination("addr", type: .bitcoinAddress)
        let payment = legacyBuilderSetChildPlatform(
            builder, name: "Acme", logoURL: "https://example.com/a.png", logoLightURL: "https://example.com/a-light.png"
        ).build()
        XCTAssertEqual(payment.brand?.name, "Acme")
        let object = try wireObject(payment)
        XCTAssertEqual(brandBody(object), expected)
        XCTAssertNil(object["child_platform"])
    }

    @available(*, deprecated)
    func testPaymentWithOnlyDeprecatedPropertySerializesAsBrand() throws {
        let payment = legacyPayment(childPlatform: Platform(name: "Acme", logoURL: "https://example.com/a.png", logoLightURL: "https://example.com/a-light.png"))
        let object = try wireObject(payment)
        XCTAssertEqual(brandBody(object), expected)
        XCTAssertNil(object["child_platform"])
    }

    @available(*, deprecated)
    func testAssigningDeprecatedPropertySerializesAsBrand() throws {
        var payment = Payment(destinations: [Destination(value: "abc")])
        setLegacyChildPlatform(&payment, Platform(name: "Acme"))
        let object = try wireObject(payment)
        XCTAssertEqual(brandBody(object), ["name": "Acme"])
        XCTAssertNil(object["child_platform"])
    }

    @available(*, deprecated)
    func testBrandWinsWhenBothAreSet() throws {
        let payment = legacyPayment(childPlatform: Platform(name: "Old"), brand: Platform(name: "New"))
        let object = try wireObject(payment)
        XCTAssertEqual(brandBody(object), ["name": "New"])
        XCTAssertNil(object["child_platform"])
    }

    func testNoBrandOmitsKey() throws {
        let object = try wireObject(Payment(destinations: [Destination(value: "abc")]))
        XCTAssertNil(object["brand"])
        XCTAssertNil(object["child_platform"])
    }

    @available(*, deprecated)
    func testParseBrand() throws {
        let payment = try WireCoding.decodePayment(Data(#"{"destinations":[],"brand":{"name":"B","logo_url":"https://x/l.png"}}"#.utf8))
        XCTAssertEqual(payment.brand?.name, "B")
        XCTAssertEqual(payment.brand?.logoURL, "https://x/l.png")
        XCTAssertEqual(legacyChildPlatform(of: payment)?.name, "B")
    }

    @available(*, deprecated)
    func testParseChildPlatformPopulatesBrandAndMirror() throws {
        let payment = try WireCoding.decodePayment(Data(#"{"destinations":[],"child_platform":{"name":"C","logo_light_url":"https://x/ll.png"}}"#.utf8))
        XCTAssertEqual(payment.brand?.name, "C")
        XCTAssertEqual(payment.brand?.logoLightURL, "https://x/ll.png")
        XCTAssertEqual(legacyChildPlatform(of: payment)?.name, "C")
        XCTAssertEqual(legacyChildPlatform(of: payment)?.logoLightURL, "https://x/ll.png")
    }

    @available(*, deprecated)
    func testParseBothBrandWins() throws {
        let payment = try WireCoding.decodePayment(Data(#"{"destinations":[],"brand":{"name":"B"},"child_platform":{"name":"C"}}"#.utf8))
        XCTAssertEqual(payment.brand?.name, "B")
        XCTAssertEqual(legacyChildPlatform(of: payment)?.name, "B")
    }

    @available(*, deprecated)
    func testParseNeitherLeavesNil() throws {
        let payment = try WireCoding.decodePayment(Data(#"{"destinations":[]}"#.utf8))
        XCTAssertNil(payment.brand)
        XCTAssertNil(legacyChildPlatform(of: payment))
    }

    private func makeService(_ client: FakeClient, _ aes: FakeAES) -> BrantaService {
        BrantaService(
            options: BrantaApiOptions(environment: .localhost),
            client: client,
            aes: aes,
            secretGenerator: FakeSecrets(["bitcoin-secret"])
        )
    }

    func testAddPaymentLeavesCallerUnchangedAndCopyCarriesBrand() async throws {
        let client = FakeClient()
        let aes = FakeAES()
        let payment = PaymentBuilder()
            .addDestination("1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa", type: .bitcoinAddress)
            .setBrand(name: "Acme", logoURL: "https://example.com/a.png")
            .build()
        _ = try await makeService(client, aes).addPayment(payment)
        XCTAssertEqual(payment.destinations[0].value, "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa")
        XCTAssertEqual(payment.brand?.name, "Acme")
        XCTAssertEqual(client.posts[0].brand?.name, "Acme")
        XCTAssertEqual(client.posts[0].brand?.logoURL, "https://example.com/a.png")
        XCTAssertNotEqual(client.posts[0].destinations[0].value, payment.destinations[0].value)
    }

    @available(*, deprecated)
    func testAddPaymentNormalizesOldStyleChildPlatformIntoBrandCopy() async throws {
        let client = FakeClient()
        let aes = FakeAES()
        let payment = legacyPayment(childPlatform: Platform(name: "Old"))
        var caller = payment
        caller.destinations = [Destination(value: "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa", type: .bitcoinAddress)]
        _ = try await makeService(client, aes).addPayment(caller)
        XCTAssertEqual(client.posts[0].brand?.name, "Old")
        XCTAssertEqual(legacyChildPlatform(of: client.posts[0])?.name, "Old")
        // Caller untouched: still old-style only.
        XCTAssertNil(caller.brand)
        XCTAssertEqual(legacyChildPlatform(of: caller)?.name, "Old")
        XCTAssertEqual(caller.destinations[0].value, "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa")
    }

    @available(*, deprecated)
    func testAddPaymentBrandWinsOverChildPlatformInCopy() async throws {
        let client = FakeClient()
        let aes = FakeAES()
        var caller = legacyPayment(childPlatform: Platform(name: "Old"), brand: Platform(name: "New"))
        caller.destinations = [Destination(value: "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa", type: .bitcoinAddress)]
        _ = try await makeService(client, aes).addPayment(caller)
        XCTAssertEqual(client.posts[0].brand?.name, "New")
        XCTAssertEqual(legacyChildPlatform(of: client.posts[0])?.name, "New")
    }
}
