import Foundation

public struct Platform: Equatable, Sendable {
    public var name: String?
    public var logoURL: String?
    public var logoLightURL: String?

    public init(name: String? = nil, logoURL: String? = nil, logoLightURL: String? = nil) {
        self.name = name
        self.logoURL = logoURL
        self.logoLightURL = logoLightURL
    }
}

public final class Destination {
    public var value: String
    public var isPrimary: Bool
    public var isZk: Bool
    public var type: DestinationType?
    public var zkID: String?
    public var encryptedDek: String?
    /// Client-side only. True while a ZK destination has not been decrypted.
    public var isEncrypted: Bool

    public init(
        value: String,
        isPrimary: Bool = false,
        isZk: Bool = false,
        type: DestinationType? = nil,
        zkID: String? = nil,
        encryptedDek: String? = nil,
        isEncrypted: Bool = false
    ) {
        self.value = value
        self.isPrimary = isPrimary
        self.isZk = isZk
        self.type = type
        self.zkID = zkID
        self.encryptedDek = encryptedDek
        self.isEncrypted = isEncrypted
    }
}

public final class Payment {
    public var description: String?
    public var destinations: [Destination]
    public var createdAt: String?
    public var ttl: Int
    public var metadata: String?
    public var platform: String?
    public var platformLogoURL: String?
    public var platformLogoLightURL: String?
    public var parentPlatform: Platform?
    public var childPlatform: Platform?
    public var btcPayServerPluginVersion: String?
    /// Client-side only. True after metadata was decrypted with a destination DEK.
    public var isMetadataDecrypted: Bool

    public init(
        description: String? = nil,
        destinations: [Destination] = [],
        createdAt: String? = nil,
        ttl: Int = 0,
        metadata: String? = nil,
        platform: String? = nil,
        platformLogoURL: String? = nil,
        platformLogoLightURL: String? = nil,
        parentPlatform: Platform? = nil,
        childPlatform: Platform? = nil,
        btcPayServerPluginVersion: String? = nil,
        isMetadataDecrypted: Bool = false
    ) {
        self.description = description
        self.destinations = destinations
        self.createdAt = createdAt
        self.ttl = ttl
        self.metadata = metadata
        self.platform = platform
        self.platformLogoURL = platformLogoURL
        self.platformLogoLightURL = platformLogoLightURL
        self.parentPlatform = parentPlatform
        self.childPlatform = childPlatform
        self.btcPayServerPluginVersion = btcPayServerPluginVersion
        self.isMetadataDecrypted = isMetadataDecrypted
    }

    public func defaultValue() throws -> String {
        guard let value = destinations.first?.value else {
            throw BrantaPaymentError(message: "No destinations found")
        }
        return value
    }
}

public struct PaymentsResult {
    public var payments: [Payment]
    public var verifyURL: String

    public init(payments: [Payment] = [], verifyURL: String = "") {
        self.payments = payments
        self.verifyURL = verifyURL
    }
}

public struct AddPaymentResult {
    public var payment: Payment
    public var secret: String
    public var verifyURL: String

    public init(payment: Payment, secret: String, verifyURL: String) {
        self.payment = payment
        self.secret = secret
        self.verifyURL = verifyURL
    }
}

enum WireCoding {
    static func encode(_ payment: Payment) throws -> Data {
        try JSONSerialization.data(withJSONObject: paymentObject(payment))
    }

    static func decodePayments(_ data: Data) throws -> [Payment] {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let array = object as? [Any] else {
            throw BrantaPaymentError(message: "Expected a payment array")
        }
        return try array.map { item in
            guard let object = item as? [String: Any] else {
                throw BrantaPaymentError(message: "Expected a payment object")
            }
            return payment(from: object)
        }
    }

    static func decodePayment(_ data: Data) throws -> Payment {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw BrantaPaymentError(message: "Expected a payment object")
        }
        return payment(from: dictionary)
    }

    private static func paymentObject(_ payment: Payment) -> [String: Any] {
        var object: [String: Any] = [
            "destinations": payment.destinations.map(destinationObject),
            "ttl": payment.ttl,
        ]
        if let description = payment.description { object["description"] = description }
        if let createdAt = payment.createdAt { object["created_at"] = createdAt }
        if let metadata = payment.metadata { object["metadata"] = metadata }
        if let platform = payment.platform { object["platform"] = platform }
        if let logo = payment.platformLogoURL { object["platform_logo_url"] = logo }
        if let logo = payment.platformLogoLightURL { object["platform_logo_light_url"] = logo }
        if let child = payment.childPlatform { object["child_platform"] = platformObject(child) }
        if let version = payment.btcPayServerPluginVersion {
            object["btc_pay_server_plugin_version"] = version
        }
        return object
    }

    private static func destinationObject(_ destination: Destination) -> [String: Any] {
        var object: [String: Any] = [
            "value": destination.value,
            "primary": destination.isPrimary,
            "zk": destination.isZk,
        ]
        if let type = destination.type { object["type"] = type.rawValue }
        if let zkID = destination.zkID { object["zk_id"] = zkID }
        if let dek = destination.encryptedDek { object["encrypted_dek"] = dek }
        return object
    }

    private static func platformObject(_ platform: Platform) -> [String: Any] {
        var object: [String: Any] = [:]
        if let name = platform.name { object["name"] = name }
        if let logo = platform.logoURL { object["logo_url"] = logo }
        if let logo = platform.logoLightURL { object["logo_light_url"] = logo }
        return object
    }

    private static func payment(from object: [String: Any]) -> Payment {
        let destinations = (object["destinations"] as? [Any] ?? []).compactMap { item -> Destination? in
            guard let dictionary = item as? [String: Any] else { return nil }
            return destination(from: dictionary)
        }
        return Payment(
            description: object["description"] as? String,
            destinations: destinations,
            createdAt: object["created_at"] as? String,
            ttl: intValue(object["ttl"]) ?? 0,
            metadata: object["metadata"] as? String,
            platform: object["platform"] as? String,
            platformLogoURL: object["platform_logo_url"] as? String,
            platformLogoLightURL: object["platform_logo_light_url"] as? String,
            parentPlatform: platform(from: object["parent_platform"]),
            childPlatform: platform(from: object["child_platform"]),
            btcPayServerPluginVersion: object["btc_pay_server_plugin_version"] as? String
                ?? object["btcpay_server_plugin_version"] as? String
        )
    }

    private static func destination(from object: [String: Any]) -> Destination {
        let type = (object["type"] as? String).flatMap(DestinationType.init(rawValue:))
        return Destination(
            value: object["value"] as? String ?? "",
            isPrimary: boolValue(object["primary"]),
            isZk: boolValue(object["zk"]),
            type: type,
            zkID: object["zk_id"] as? String ?? object["zkId"] as? String,
            encryptedDek: object["encrypted_dek"] as? String
        )
    }

    private static func platform(from value: Any?) -> Platform? {
        guard let object = value as? [String: Any] else { return nil }
        return Platform(
            name: object["name"] as? String,
            logoURL: object["logo_url"] as? String,
            logoLightURL: object["logo_light_url"] as? String
        )
    }

    private static func boolValue(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }
}
