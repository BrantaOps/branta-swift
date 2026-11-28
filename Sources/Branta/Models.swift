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
    /// Payee the platform tags the payment with. Sent as `brand` on the wire.
    public var brand: Platform?
    /// Backing storage for the deprecated `childPlatform` property. Internal code reads and writes this, never the deprecated name.
    var legacyChildPlatform: Platform?
    /// Deprecated name for `brand`. Reads the effective brand (`brand`, else the value last assigned here). Assigning it stores a fallback that is used only while `brand` is nil.
    @available(*, deprecated, renamed: "brand")
    public var childPlatform: Platform? {
        get { effectiveBrand }
        set { legacyChildPlatform = newValue }
    }
    /// `brand` if set, otherwise the deprecated `childPlatform`.
    var effectiveBrand: Platform? { brand ?? legacyChildPlatform }
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
        brand: Platform? = nil,
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
        self.brand = brand
        self.isMetadataDecrypted = isMetadataDecrypted
    }

    /// Deprecated: use `init(...brand:...)`. `childPlatform` is required here so calls that omit it resolve to the main initializer.
    @available(*, deprecated, message: "Use brand instead of childPlatform.")
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
        brand: Platform? = nil,
        childPlatform: Platform?,
        isMetadataDecrypted: Bool = false
    ) {
        self.init(
            description: description,
            destinations: destinations,
            createdAt: createdAt,
            ttl: ttl,
            metadata: metadata,
            platform: platform,
            platformLogoURL: platformLogoURL,
            platformLogoLightURL: platformLogoLightURL,
            parentPlatform: parentPlatform,
            brand: brand,
            isMetadataDecrypted: isMetadataDecrypted
        )
        self.legacyChildPlatform = childPlatform
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
