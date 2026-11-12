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
    /// Decrypted rails that bound the scan on `match` (token is on `type`, not the URI scheme).
    public var matchedDestinations: [Destination]
    public var verifyURL: String

    public init(
        status: VerifyStatus,
        payments: [Payment] = [],
        matchedDestinations: [Destination] = [],
        verifyURL: String
    ) {
        self.status = status
        self.payments = payments
        self.matchedDestinations = matchedDestinations
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
