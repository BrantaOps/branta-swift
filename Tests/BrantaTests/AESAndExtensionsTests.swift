import XCTest
@testable import Branta

final class AESTests: XCTestCase {
    func testRoundTrip() throws {
        let secret = "test-secret"
        let encrypted = try AESEncryption.encrypt(value: "test-value", secret: secret)
        XCTAssertEqual(try AESEncryption.decrypt(encryptedValue: encrypted, secret: secret), "test-value")
    }

    func testWrongSecretFails() throws {
        let encrypted = try AESEncryption.encrypt(value: "value", secret: "correct-secret")
        XCTAssertThrowsError(try AESEncryption.decrypt(encryptedValue: encrypted, secret: "wrong-secret"))
    }

    func testRandomNonceDiffers() throws {
        let first = try AESEncryption.encrypt(value: "value", secret: "secret", deterministicNonce: false)
        let second = try AESEncryption.encrypt(value: "value", secret: "secret", deterministicNonce: false)
        XCTAssertNotEqual(first, second)
    }

    func testDeterministicNonceIsStable() throws {
        let first = try AESEncryption.encrypt(value: "value", secret: "secret", deterministicNonce: true)
        let second = try AESEncryption.encrypt(value: "value", secret: "secret", deterministicNonce: true)
        XCTAssertEqual(first, second)
    }

    func testTooShortPayload() {
        let short = Data(repeating: 1, count: 10).base64EncodedString()
        XCTAssertThrowsError(try AESEncryption.decrypt(encryptedValue: short, secret: "secret")) { error in
            XCTAssertEqual((error as? AESError)?.message, "Invalid encrypted data: too short")
        }
    }

    func testCrossSDKFixedVector() throws {
        let expected = "mPIKHc3ywVlsBHf3Lv2Rwpz2+fKE0kgUePq2m4fPIUidMuGEHVIB"
        XCTAssertEqual(try AESEncryption.encrypt(value: "hello world", secret: "my-secret", deterministicNonce: true), expected)
        XCTAssertEqual(try AESEncryption.decrypt(encryptedValue: expected, secret: "my-secret"), "hello world")
    }

    func testDeterministicBolt11RoundTrip() throws {
        let value = "lnbc100n1ptest"
        let key = normalizedHash(value)
        let encrypted = try AESEncryption.encrypt(value: value, secret: key, deterministicNonce: true)
        XCTAssertEqual(try AESEncryption.decrypt(encryptedValue: encrypted, secret: key), value)
    }

    func testUnicodeRoundTrip() throws {
        let value = "café ☕"
        let encrypted = try AESEncryption.encrypt(value: value, secret: "unicode-secret")
        XCTAssertEqual(try AESEncryption.decrypt(encryptedValue: encrypted, secret: "unicode-secret"), value)
    }
}

final class ExtensionTests: XCTestCase {
    func testPrefixes() {
        XCTAssertTrue(isBolt11("lnbc100n1ptest"))
        XCTAssertTrue(isBolt11("lntb100n1ptest"))
        XCTAssertTrue(isBolt11("lnbcrt100n1ptest"))
        XCTAssertTrue(isBolt11("LNBC100N1PTEST"))
        XCTAssertFalse(isBolt11("1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"))
        XCTAssertTrue(isArk("ark1testaddress"))
        XCTAssertTrue(isArk("ARK1TESTADDRESS"))
        XCTAssertFalse(isArk("bc1qtest"))
        XCTAssertTrue(isSilentPayment("sp1testaddress"))
        XCTAssertTrue(isSilentPayment("tsp1testaddress"))
        XCTAssertFalse(isSilentPayment("bc1qtest"))
    }

    func testHashZKType() {
        XCTAssertEqual(hashZKType(of: "lnbc100n1ptest"), .bolt11)
        XCTAssertEqual(hashZKType(of: "ark1testaddress"), .arkAddress)
        XCTAssertEqual(hashZKType(of: "sp1testaddress"), .silentPayment)
        XCTAssertNil(hashZKType(of: "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"))
    }

    func testNormalizedHash() {
        XCTAssertEqual(normalizedHash("lnbc100n1ptest"), normalizedHash("LNBC100N1PTEST"))
        XCTAssertTrue(normalizedHash("test").range(of: "^[0-9A-F]+$", options: .regularExpression) != nil)
    }

    func testURLFragment() {
        XCTAssertEqual(urlFragment(for: [("id1", "secret1"), ("id2", "secret2")]), "#k-id1=secret1&k-id2=secret2")
        XCTAssertEqual(urlFragment(for: [("abc", "xyz")]), "#k-abc=xyz")
    }

    func testJavaURLEncoding() {
        XCTAssertEqual(javaURLEncode("abc+def=="), "abc%2Bdef%3D%3D")
        XCTAssertEqual(javaURLEncode("hello world"), "hello+world")
        XCTAssertEqual(javaURLDecode("abc%2Bdef%3D%3D"), "abc+def==")
    }
}
