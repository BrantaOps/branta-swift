import XCTest
@testable import Branta

final class StubTransport: HTTPTransporting {
    var body: Data
    var statusCode: Int
    var requests: [URLRequest] = []

    init(body: String, statusCode: Int = 200) {
        self.body = Data(body.utf8)
        self.statusCode = statusCode
    }

    func send(_ request: URLRequest) async throws -> HTTPResult {
        requests.append(request)
        return HTTPResult(body: body, statusCode: statusCode)
    }
}

final class ClientTests: XCTestCase {
    private let sameOrigin = "http://localhost:3000"
    private let otherOrigin = "https://attacker.example"
    private let destinations = #"[{"value":"test-destination"}]"#

    private func client(json: String) -> BrantaClient {
        let transport = StubTransport(body: json)
        return BrantaClient(
            defaultOptions: BrantaClientOptions(baseURL: .localhost, privacy: .loose),
            transport: transport
        )
    }

    func testChecksEveryPaymentLogo() async {
        let json = """
        [
          {"destinations": \(destinations)},
          {"destinations": \(destinations), "platform_logo_url": "\(otherOrigin)/logo.png"}
        ]
        """
        do {
            _ = try await client(json: json).getPayments(destinationValue: "value", options: nil)
            XCTFail("expected throw")
        } catch let error as BrantaPaymentError {
            XCTAssertTrue(error.message.contains("platformLogoUrl"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testMismatchedLightAndNestedLogos() async throws {
        let cases: [(String, String)] = [
            (#"[{"destinations": \#(destinations), "platform_logo_light_url": "\#(otherOrigin)/logo-light.png"}]"#, "platformLogoLightUrl"),
            (#"[{"destinations": \#(destinations), "parent_platform": {"logo_url": "\#(otherOrigin)/logo.png"}}]"#, "parentPlatform.logoUrl"),
            (#"[{"destinations": \#(destinations), "parent_platform": {"logo_light_url": "\#(otherOrigin)/logo-light.png"}}]"#, "parentPlatform.logoLightUrl"),
            (#"[{"destinations": \#(destinations), "child_platform": {"logo_url": "\#(otherOrigin)/logo.png"}}]"#, "childPlatform.logoUrl"),
            (#"[{"destinations": \#(destinations), "child_platform": {"logo_light_url": "\#(otherOrigin)/logo-light.png"}}]"#, "childPlatform.logoLightUrl"),
        ]
        for (json, field) in cases {
            do {
                _ = try await client(json: json).getPayments(destinationValue: "value", options: nil)
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
        let payments = try await client(json: json).getPayments(destinationValue: "value", options: nil)
        XCTAssertEqual(payments.count, 2)
    }

    func testHMACSignsTheRawBody() async throws {
        let transport = StubTransport(body: "null", statusCode: 200)
        let client = BrantaClient(
            defaultOptions: BrantaClientOptions(baseURL: .localhost, defaultAPIKey: "key", hmacSecret: "test-secret"),
            transport: transport
        )
        client.timestamp = { "1700000000" }
        let payment = Payment(destinations: [Destination(value: "abc")], ttl: 0)
        _ = try await client.postPayment(payment, options: nil)
        let request = try XCTUnwrap(transport.requests.first)
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        let message = "POST|http://localhost:3000/v2/payments|\(body)|1700000000"
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-HMAC-Signature"), hmacSHA256Hex(secret: "test-secret", message: message))
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-HMAC-Timestamp"), "1700000000")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer key")
    }

    func testPostFailureUsesStatusCode() async {
        let transport = StubTransport(body: "", statusCode: 401)
        let client = BrantaClient(
            defaultOptions: BrantaClientOptions(baseURL: .localhost, defaultAPIKey: "key"),
            transport: transport
        )
        do {
            _ = try await client.postPayment(Payment(destinations: [Destination(value: "abc")]), options: nil)
            XCTFail("expected throw")
        } catch let error as BrantaPaymentError {
            XCTAssertEqual(error.message, "401")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}
