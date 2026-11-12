import Foundation

enum WireCoding {
    static func encode(_ payment: Payment) throws -> Data {
        try JSONSerialization.data(withJSONObject: paymentObject(payment))
    }

    /// Decodes a GET payments body. Empty / null / non-array bodies return `[]`
    /// (match JS/Python). Malformed JSON still throws for the caller to map to `incomplete`.
    static func decodePayments(_ data: Data) throws -> [Payment] {
        if data.isEmpty { return [] }
        let object = try JSONSerialization.jsonObject(with: data)
        if object is NSNull { return [] }
        guard let array = object as? [Any] else {
            return []
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
