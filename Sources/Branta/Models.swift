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

public struct Destination: Sendable {
    public var value: String
    public var isPrimary: Bool
    /// Client-side only. True when a GET row has `zk` true and still needs decrypt.
    public var isEncrypted: Bool
    public var type: DestinationType?
    /// Serializes as `zk_id`. `addPayment` assigns one when this is empty.
    public var id: String?
    public var encryptedDek: String?

    public init(
        value: String,
        isPrimary: Bool = false,
        type: DestinationType? = nil,
        id: String? = nil,
        encryptedDek: String? = nil,
        isEncrypted: Bool = false
    ) {
        self.value = value
        self.isPrimary = isPrimary
        self.type = type
        self.id = id
        self.encryptedDek = encryptedDek
        self.isEncrypted = isEncrypted
    }
}

public struct Payment: Sendable {
    /// Not a plaintext API field. `addPayment` folds this into encrypted metadata, and `verify` lifts it back after decrypt.
    public var description: String?
    public var destinations: [Destination]
    public var createdAt: String?
    /// Seconds. Zero is unset and is left off the POST so Guardrail applies its default.
    public var ttl: Int
    public var metadata: String?
    public var platform: String?
    public var platformLogoURL: String?
    public var platformLogoLightURL: String?
    /// Deserialize-only. The server sets this; a POST never sends it.
    public var parentPlatform: Platform?
    public var childPlatform: Platform?
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
        self.isMetadataDecrypted = isMetadataDecrypted
    }
}

public struct VerifyResult {
    public var status: VerifyStatus
    public var payments: [Payment]
    public var verifyURL: String

    public init(status: VerifyStatus, payments: [Payment] = [], verifyURL: String) {
        self.status = status
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
        if data.isEmpty { return [] }
        let object = try JSONSerialization.jsonObject(with: data)
        if object is NSNull { return [] }
        guard let array = object as? [Any] else {
            throw BrantaPaymentError(message: "Expected a payment array")
        }
        return try array.map { item in
            guard let object = item as? [String: Any] else {
                throw BrantaPaymentError(message: "Expected a payment object")
            }
            return try payment(from: object)
        }
    }

    static func decodePayment(_ data: Data) throws -> Payment {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw BrantaPaymentError(message: "Expected a payment object")
        }
        return try payment(from: dictionary)
    }

    private static func paymentObject(_ payment: Payment) -> [String: Any] {
        var object: [String: Any] = [
            "destinations": payment.destinations.map(destinationObject),
        ]
        if payment.ttl != 0 { object["ttl"] = payment.ttl }
        if let createdAt = payment.createdAt { object["created_at"] = createdAt }
        if let metadata = payment.metadata { object["metadata"] = metadata }
        if let platform = payment.platform { object["platform"] = platform }
        if let logo = payment.platformLogoURL { object["platform_logo_url"] = logo }
        if let logo = payment.platformLogoLightURL { object["platform_logo_light_url"] = logo }
        if let child = payment.childPlatform { object["child_platform"] = platformObject(child) }
        return object
    }

    private static func destinationObject(_ destination: Destination) -> [String: Any] {
        var object: [String: Any] = [
            "value": destination.value,
            "primary": destination.isPrimary,
            "zk": true,
        ]
        if let type = destination.type { object["type"] = type.rawValue }
        if let id = destination.id, !id.isEmpty { object["zk_id"] = id }
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

    private static func payment(from object: [String: Any]) throws -> Payment {
        let rawDestinations = object["destinations"]
        let destinationItems: [Any]
        if rawDestinations == nil || rawDestinations is NSNull {
            destinationItems = []
        } else if let array = rawDestinations as? [Any] {
            destinationItems = array
        } else {
            throw BrantaPaymentError(message: "Expected a destinations array")
        }
        let destinations = try destinationItems.map { item -> Destination in
            guard let dictionary = item as? [String: Any] else {
                throw BrantaPaymentError(message: "Expected a destination object")
            }
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
            childPlatform: platform(from: object["child_platform"])
        )
    }

    private static func destination(from object: [String: Any]) -> Destination {
        let type = (object["type"] as? String).flatMap(DestinationType.init(rawValue:))
        return Destination(
            value: object["value"] as? String ?? "",
            isPrimary: boolValue(object["primary"]),
            type: type,
            id: object["zk_id"] as? String ?? object["zkId"] as? String,
            encryptedDek: object["encrypted_dek"] as? String,
            isEncrypted: boolValue(object["zk"])
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
        if value is NSNull { return false }
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }

    private static func intValue(_ value: Any?) -> Int? {
        if value is NSNull { return nil }
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }
}
