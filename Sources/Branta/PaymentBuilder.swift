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

    @discardableResult
    public func setZK() -> PaymentBuilder {
        guard let index = destinations.indices.last else { return self }
        destinations[index].isZk = true
        destinations[index].zkID = UUID().uuidString.lowercased()
        return self
    }

    @discardableResult
    public func setDescription(_ description: String) -> PaymentBuilder {
        self.description = description
        return self
    }

    @discardableResult
    public func addMetadata(key: String, value: String) -> PaymentBuilder {
        var map: [String: String] = [:]
        if let metadata, !metadata.isEmpty,
           let data = metadata.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (existingKey, existingValue) in parsed {
                map[existingKey] = stringValue(existingValue)
            }
        }
        map[key] = value
        if let data = try? JSONSerialization.data(withJSONObject: map),
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

    private func stringValue(_ value: Any) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return String(describing: value)
    }
}
