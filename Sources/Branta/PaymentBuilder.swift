import Foundation

public final class PaymentBuilder {
    private var destinations: [Destination] = []
    private var description: String?
    private var metadata: String?
    private var ttl: Int = 0
    private var platformLogoURL: String?
    private var childPlatform: Platform?

    public init() {}

    @discardableResult
    public func addDestination(_ address: String, type: DestinationType? = nil) -> PaymentBuilder {
        destinations.append(Destination(value: address, type: type))
        return self
    }

    /// Stored on the payment and folded into encrypted metadata by `addPayment`.
    @discardableResult
    public func setDescription(_ description: String) -> PaymentBuilder {
        self.description = description
        return self
    }

    @discardableResult
    public func addMetadata(key: String, value: String) -> PaymentBuilder {
        var map: [String: Any] = [:]
        if let metadata, !metadata.isEmpty,
           let data = metadata.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            map = parsed
        }
        map[key] = value
        if JSONSerialization.isValidJSONObject(map),
           let data = try? JSONSerialization.data(withJSONObject: map),
           let encoded = String(data: data, encoding: .utf8) {
            self.metadata = encoded
        }
        return self
    }

    @discardableResult
    public func setTTL(_ ttl: Int) -> PaymentBuilder {
        self.ttl = ttl
        return self
    }

    @discardableResult
    public func setPlatformLogoURL(_ platformLogoURL: String) -> PaymentBuilder {
        self.platformLogoURL = platformLogoURL
        return self
    }

    @discardableResult
    public func setChildPlatform(name: String, logoURL: String? = nil, logoLightURL: String? = nil) -> PaymentBuilder {
        childPlatform = Platform(name: name, logoURL: logoURL, logoLightURL: logoLightURL)
        return self
    }

    public func build() -> Payment {
        Payment(
            description: description,
            destinations: destinations,
            ttl: ttl,
            metadata: metadata,
            platformLogoURL: platformLogoURL,
            childPlatform: childPlatform
        )
    }
}
