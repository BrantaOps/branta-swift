import XCTest
@testable import Branta

final class StubTransport: HTTPTransporting {
    var body: Data
    var statusCode: Int
    var requests: [URLRequest] = []
    var error: Error?

    init(body: String, statusCode: Int = 200) {
        self.body = Data(body.utf8)
        self.statusCode = statusCode
    }

    func send(_ request: URLRequest) async throws -> HTTPResult {
        requests.append(request)
        if let error { throw error }
        return HTTPResult(body: body, statusCode: statusCode)
    }
}

final class ClientTests: XCTestCase {
    private let sameOrigin = "http://localhost:3000"
    private let otherOrigin = "https://attacker.example"
    private let destinations = #"[{"value":"test-destination"}]"#

    private func client(json: String, statusCode: Int = 200, token: String = "") -> (BrantaClient, StubTransport) {
        let transport = StubTransport(body: json, statusCode: statusCode)
        let client = BrantaClient(
            defaultOptions: BrantaApiOptions(environment: .localhost),
            transport: transport
        )
        client.integrationMetricsToken = token
        return (client, transport)
    }

    func testChecksEveryPaymentLogo() async {
        let json = """
        [
          {"destinations": \(destinations)},
          {"destinations": \(destinations), "platform_logo_url": "\(otherOrigin)/logo.png"}
        ]
        """
        do {
            _ = try await client(json: json).0.getPayments(destinationValue: "value", options: nil)
            XCTFail("expected throw")
        } catch let error as BrantaPaymentError {
            XCTAssertTrue(error.message.contains("platformLogoURL"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testMismatchedLightAndNestedLogos() async throws {
        let cases: [(String, String)] = [
            (#"[{"destinations": \#(destinations), "platform_logo_light_url": "\#(otherOrigin)/logo-light.png"}]"#, "platformLogoLightURL"),
            (#"[{"destinations": \#(destinations), "parent_platform": {"logo_url": "\#(otherOrigin)/logo.png"}}]"#, "parentPlatform.logoURL"),
            (#"[{"destinations": \#(destinations), "parent_platform": {"logo_light_url": "\#(otherOrigin)/logo-light.png"}}]"#, "parentPlatform.logoLightURL"),
            (#"[{"destinations": \#(destinations), "child_platform": {"logo_url": "\#(otherOrigin)/logo.png"}}]"#, "childPlatform.logoURL"),
            (#"[{"destinations": \#(destinations), "child_platform": {"logo_light_url": "\#(otherOrigin)/logo-light.png"}}]"#, "childPlatform.logoLightURL"),
        ]
        for (json, field) in cases {
            do {
                _ = try await client(json: json).0.getPayments(destinationValue: "value", options: nil)
                XCTFail("expected \(field)")
            } catch let error as BrantaPaymentError {
                XCTAssertTrue(error.message.contains(field), error.message)
            }
        }
    }

    func testSameOriginLogosPass() async throws {
        let json = """
        [
          {
            "destinations": \(destinations),
            "platform_logo_url": "\(sameOrigin)/a.png",
            "platform_logo_light_url": "\(sameOrigin)/b.png",
            "parent_platform": {"logo_url": "\(sameOrigin)/c.png", "logo_light_url": "\(sameOrigin)/d.png"},
            "child_platform": {"logo_url": "\(sameOrigin)/e.png"}
          },
          {"destinations": \(destinations)}
        ]
        """
        let payments = try await client(json: json).0.getPayments(destinationValue: "value", options: nil)
        XCTAssertEqual(payments.count, 2)
    }

    func testNotFoundIsEmptyAndOtherErrorsAreIncomplete() async throws {
        let missing = try await client(json: "nope", statusCode: 404).0.getPayments(destinationValue: "value", options: nil)
        XCTAssertTrue(missing.isEmpty)
        do {
            _ = try await client(json: "nope", statusCode: 500).0.getPayments(destinationValue: "value", options: nil)
            XCTFail("expected incomplete")
        } catch LookupFailure.incomplete {
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testMalformedJSONThrows() async {
        do {
            _ = try await client(json: "{").0.getPayments(destinationValue: "value", options: nil)
            XCTFail("expected throw")
        } catch is BrantaPaymentError {
            XCTFail("malformed JSON is not a payment error status")
        } catch {
            XCTAssertFalse(error is LookupFailure)
        }
    }

    func testPathEncodesPlusSlashEqualsAndSendsMetricsToken() async throws {
        let (http, transport) = client(json: "[]", token: "metrics")
        _ = try await http.getPayments(destinationValue: "abc+def/g==", options: nil)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertTrue(request.url?.absoluteString.contains("/v2/payments/abc%2Bdef%2Fg%3D%3D") == true)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Branta-Integration-Token"), "metrics")

        let (plain, plainTransport) = client(json: "[]")
        _ = try await plain.getPayments(destinationValue: "abc", options: nil)
        XCTAssertNil(plainTransport.requests.first?.value(forHTTPHeaderField: "X-Branta-Integration-Token"))
    }

    func testTransportFailureIsIncomplete() async {
        let (http, transport) = client(json: "[]")
        transport.error = URLError(.notConnectedToInternet)
        do {
            _ = try await http.getPayments(destinationValue: "value", options: nil)
            XCTFail("expected incomplete")
        } catch LookupFailure.incomplete {
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testHMACSignsTheRawBody() async throws {
        let transport = StubTransport(body: "null", statusCode: 200)
        let client = BrantaClient(
            defaultOptions: BrantaApiOptions(environment: .localhost, apiKey: "key", hmacSecret: "test-secret"),
            transport: transport
        )
        client.timestamp = { "1700000000" }
        let payment = Payment(destinations: [Destination(value: "abc")], ttl: 0)
        _ = try await client.postPayment(payment, options: nil)
        let request = try XCTUnwrap(transport.requests.first)
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertFalse(body.contains("ttl"))
        let message = "POST|http://localhost:3000/v2/payments|\(body)|1700000000"
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-HMAC-Signature"), hmacSHA256Hex(secret: "test-secret", message: message))
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-HMAC-Timestamp"), "1700000000")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer key")
    }

    func testPostFailureUsesStatusCode() async {
        let transport = StubTransport(body: "", statusCode: 401)
        let client = BrantaClient(
            defaultOptions: BrantaApiOptions(environment: .localhost, apiKey: "key"),
            transport: transport
        )
        do {
            _ = try await client.postPayment(Payment(destinations: [Destination(value: "abc")]), options: nil)
            XCTFail("expected throw")
        } catch let error as BrantaPaymentError {
            XCTAssertEqual(error.message, "request failed with status 401")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testPostWithoutAPIKeyDoesNotSend() async {
        let transport = StubTransport(body: "")
        let client = BrantaClient(defaultOptions: BrantaApiOptions(environment: .localhost), transport: transport)
        do {
            _ = try await client.postPayment(Payment(destinations: [Destination(value: "abc")]), options: nil)
            XCTFail("expected throw")
        } catch let error as BrantaPaymentError {
            XCTAssertEqual(error.message, "Unauthorized")
            XCTAssertTrue(transport.requests.isEmpty)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}
