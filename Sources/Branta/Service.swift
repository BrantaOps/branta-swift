import Foundation

protocol SecretGenerating {
    func generate() -> String
    var deterministicNonce: Bool { get }
}

struct GuidSecretGenerator: SecretGenerating {
    func generate() -> String { UUID().uuidString.lowercased() }
    var deterministicNonce: Bool { false }
}

public final class BrantaService {
    private let defaultOptions: BrantaApiOptions?
    private let client: BrantaClienting
    private let aes: AESEncrypting
    private let secretGenerator: SecretGenerating

    public init(options: BrantaApiOptions = BrantaApiOptions()) {
        self.defaultOptions = options
        self.client = BrantaClient(defaultOptions: options)
        self.aes = AESEncryptionService()
        self.secretGenerator = GuidSecretGenerator()
    }

    init(
        options: BrantaApiOptions?,
        client: BrantaClienting,
        aes: AESEncrypting,
        secretGenerator: SecretGenerating
    ) {
        self.defaultOptions = options
        self.client = client
        self.aes = aes
        self.secretGenerator = secretGenerator
    }

    /// Parses a scanned QR or pasted text and looks it up.
    ///
    /// A swapped address or a derived-key plaintext that is not the scanned value is `tampered`.
    /// A 404 is `unknown`. Any other non-OK response, and a network failure, is `incomplete`.
    /// A logo URL on the wrong origin still throws.
    public func verify(_ input: String, options: BrantaApiOptions? = nil) async throws -> VerifyResult {
        let parser = QRParser(input)
        let lookup = errorLookup(parser)
        do {
            return try await verifyParsed(parser, options: options)
        } catch LookupFailure.tampered {
            return VerifyResult(status: .tampered, verifyURL: buildVerifyURL(options: options, paymentLookup: lookup))
        } catch LookupFailure.incomplete {
            return VerifyResult(status: .incomplete, verifyURL: buildVerifyURL(options: options, paymentLookup: lookup))
        }
    }

    /// Encrypts a copy of `payment` and posts that copy. A failed post leaves the caller's payment plaintext.
    public func addPayment(_ payment: Payment, options: BrantaApiOptions? = nil) async throws -> AddPaymentResult {
        var submitted = payment
        foldDescriptionIntoMetadata(&submitted)

        var dek: String?
        if let metadata = submitted.metadata, !metadata.isEmpty, !submitted.destinations.isEmpty {
            dek = secretGenerator.generate()
            submitted.metadata = try aes.encrypt(value: metadata, secret: dek ?? "", deterministicNonce: false)
        }

        let secret = secretGenerator.generate()
        var encryptedToKey: [String: String] = [:]

        for index in submitted.destinations.indices {
            if submitted.destinations[index].id?.isEmpty != false {
                submitted.destinations[index].id = UUID().uuidString.lowercased()
            }

            var destType = submitted.destinations[index].type
            if destType == nil {
                destType = detectPlainTextType(submitted.destinations[index].value)
                if let destType {
                    submitted.destinations[index].type = destType
                }
            }

            if let destType, isSecretKeyAddressType(destType) {
                let ciphertext = try aes.encrypt(
                    value: submitted.destinations[index].value,
                    secret: secret,
                    deterministicNonce: secretGenerator.deterministicNonce
                )
                submitted.destinations[index].value = ciphertext
                encryptedToKey[ciphertext] = secret
                if let dek {
                    submitted.destinations[index].encryptedDek = try aes.encrypt(value: dek, secret: secret, deterministicNonce: false)
                }
                continue
            }

            guard derivedKeyType(of: submitted.destinations[index].value) != nil else {
                let name = submitted.destinations[index].type?.rawValue ?? ""
                throw BrantaPaymentError(message: "destination type '\(name)' cannot be encrypted")
            }
            let normalized = submitted.destinations[index].value.lowercased()
            let key = normalizedHash(normalized)
            let ciphertext = try aes.encrypt(value: normalized, secret: key, deterministicNonce: true)
            submitted.destinations[index].value = ciphertext
            encryptedToKey[ciphertext] = key
            if let dek {
                submitted.destinations[index].encryptedDek = try aes.encrypt(value: dek, secret: key, deterministicNonce: false)
            }
        }

        let primary = submitted.destinations.first?.value ?? ""
        guard let response = try await client.postPayment(submitted, options: options) else {
            throw BrantaPaymentError(message: "No payment returned from server.")
        }

        var keys: [(String, String)] = []
        for destination in response.destinations {
            guard let id = destination.id, !id.isEmpty, let key = encryptedToKey[destination.value] else { continue }
            if keys.contains(where: { $0.0 == id }) { continue }
            keys.append((id, key))
        }

        return AddPaymentResult(
            payment: response,
            secret: secret,
            verifyURL: buildVerifyURL(options: options, paymentLookup: primary, keys: keys)
        )
    }

    public func isAPIKeyValid(options: BrantaApiOptions? = nil) async throws -> Bool {
        try await client.isAPIKeyValid(options: options)
    }

    private func verifyParsed(_ parser: QRParser, options: BrantaApiOptions?) async throws -> VerifyResult {
        let expectedOnChain = try uniformOnChainAddress(parser)
        let lookup = errorLookup(parser)

        if parser.hasUnverifiableInstruction {
            return VerifyResult(status: .unknown, verifyURL: buildVerifyURL(options: options, paymentLookup: lookup))
        }

        if parser.isOnChainZK() {
            let additional = parser.destinations.compactMap { destination -> String? in
                derivedKeyType(of: destination.value) == nil ? nil : destination.value
            }
            if (expectedOnChain ?? "").isEmpty && additional.isEmpty {
                return VerifyResult(status: .unknown, verifyURL: buildVerifyURL(options: options, paymentLookup: lookup))
            }
            let (payments, verifyURL) = try await lookupByBrantaID(
                lookupValue: parser.onChainEncryptionText,
                encryptionKey: parser.onChainEncryptionSecret,
                additionalHashValues: additional,
                expectedOnChainAddress: expectedOnChain ?? "",
                expectedOnChainTypes: Set(parser.expectedSecretKeyTypes),
                options: options
            )
            return toVerifyResult(payments, verifyURL)
        }

        let destination = parser.destination ?? ""
        if derivedKeyType(of: destination) == nil {
            return VerifyResult(status: .unknown, verifyURL: buildVerifyURL(options: options, paymentLookup: destination))
        }

        let (payments, verifyURL) = try await lookupByDerivedKey(destination, options: options)
        return toVerifyResult(payments, verifyURL)
    }

    private func lookupByBrantaID(
        lookupValue: String,
        encryptionKey: String,
        additionalHashValues: [String],
        expectedOnChainAddress: String,
        expectedOnChainTypes: Set<DestinationType>,
        options: BrantaApiOptions?
    ) async throws -> ([Payment], String) {
        var payments = try await client.getPayments(destinationValue: lookupValue, options: options)
        var keys: [(String, String)] = []
        var bound: [Payment] = []
        for index in payments.indices {
            let onChainBound = try decryptDestinations(
                payment: &payments[index],
                encryptionKey: encryptionKey,
                keys: &keys,
                expectedOnChainAddress: expectedOnChainAddress,
                expectedOnChainTypes: expectedOnChainTypes
            )
            var hashesBound = true
            for value in additionalHashValues {
                if try !decryptDerivedKeyDestinations(payment: &payments[index], plainValue: value, keys: &keys) {
                    hashesBound = false
                }
            }
            let hasPayable = !expectedOnChainAddress.isEmpty || !additionalHashValues.isEmpty
            if hasPayable && onChainBound && hashesBound {
                bound.append(payments[index])
            }
        }
        return (bound, buildVerifyURL(options: options, paymentLookup: lookupValue, keys: keys))
    }

    private func lookupByDerivedKey(_ destinationValue: String, options: BrantaApiOptions?) async throws -> ([Payment], String) {
        let normalized = destinationValue.lowercased()
        let lookupValue = try aes.encrypt(value: normalized, secret: normalizedHash(normalized), deterministicNonce: true)
        var payments = try await client.getPayments(destinationValue: lookupValue, options: options)
        var keys: [(String, String)] = []
        var bound: [Payment] = []
        for index in payments.indices {
            if try decryptDerivedKeyDestinations(payment: &payments[index], plainValue: normalized, keys: &keys) {
                bound.append(payments[index])
            }
        }
        return (bound, buildVerifyURL(options: options, paymentLookup: lookupValue, keys: keys))
    }

    private func uniformOnChainAddress(_ parser: QRParser) throws -> String? {
        var first: String?
        for destination in parser.destinations {
            guard destination.secretKey else { continue }
            if destination.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            if first == nil {
                first = destination.value
                continue
            }
            if let first, !addressesMatch(first, destination.value) {
                throw LookupFailure.tampered
            }
        }
        return first
    }

    @discardableResult
    private func decryptDestinations(
        payment: inout Payment,
        encryptionKey: String,
        keys: inout [(String, String)],
        expectedOnChainAddress: String,
        expectedOnChainTypes: Set<DestinationType>
    ) throws -> Bool {
        var onChainBound = expectedOnChainAddress.isEmpty
        var decryptedExpectedRail = false
        for index in payment.destinations.indices {
            let destination = payment.destinations[index]
            guard destination.isEncrypted else { continue }
            guard let type = destination.type, isSecretKeyAddressType(type) else { continue }
            // Outside this QR's rail family (e.g. bitcoin when scanning eth:) — leave encrypted.
            if !expectedOnChainTypes.isEmpty && !expectedOnChainTypes.contains(type) { continue }
            if encryptionKey.isEmpty { continue }
            let decrypted: String
            do {
                decrypted = try aes.decrypt(encryptedValue: destination.value, secret: encryptionKey)
            } catch {
                continue
            }
            decryptedExpectedRail = true
            // Match-if-any within the family: a sibling rail with a different address stays encrypted.
            if !expectedOnChainAddress.isEmpty && !addressesMatch(decrypted, expectedOnChainAddress) {
                continue
            }
            if !expectedOnChainAddress.isEmpty { onChainBound = true }
            payment.destinations[index].value = decrypted
            payment.destinations[index].isEncrypted = false
            putIfAbsent(id: destination.id, key: encryptionKey, into: &keys)
            tryDecryptMetadata(payment: &payment, index: index, keyUsed: encryptionKey)
        }
        // Tampered only when a family rail decrypted and none matched the scanned address.
        if !expectedOnChainAddress.isEmpty && !onChainBound && decryptedExpectedRail {
            throw LookupFailure.tampered
        }
        return onChainBound
    }

    @discardableResult
    private func decryptDerivedKeyDestinations(
        payment: inout Payment,
        plainValue: String,
        keys: inout [(String, String)]
    ) throws -> Bool {
        guard let derived = derivedKeyType(of: plainValue) else { return false }
        let key = normalizedHash(plainValue)
        var bound = false
        for index in payment.destinations.indices {
            let destination = payment.destinations[index]
            guard destination.isEncrypted, destination.type == derived else { continue }
            let plaintext: String
            do {
                plaintext = try aes.decrypt(encryptedValue: destination.value, secret: key)
            } catch {
                continue
            }
            if plaintext.lowercased() != plainValue.lowercased() {
                throw LookupFailure.tampered
            }
            payment.destinations[index].value = plaintext
            payment.destinations[index].isEncrypted = false
            putIfAbsent(id: destination.id, key: key, into: &keys)
            tryDecryptMetadata(payment: &payment, index: index, keyUsed: key)
            bound = true
        }
        return bound
    }

    private func tryDecryptMetadata(payment: inout Payment, index: Int, keyUsed: String) {
        guard let encryptedDek = payment.destinations[index].encryptedDek, payment.metadata != nil, !payment.isMetadataDecrypted else { return }
        do {
            let dek = try aes.decrypt(encryptedValue: encryptedDek, secret: keyUsed)
            payment.metadata = try aes.decrypt(encryptedValue: payment.metadata ?? "", secret: dek)
            payment.isMetadataDecrypted = true
            liftDescriptionFromMetadata(&payment)
        } catch {
            return
        }
    }

    private func putIfAbsent(id: String?, key: String, into keys: inout [(String, String)]) {
        guard let id, !id.isEmpty, !keys.contains(where: { $0.0 == id }) else { return }
        keys.append((id, key))
    }

    private func errorLookup(_ parser: QRParser) -> String {
        if !parser.onChainEncryptionText.isEmpty { return parser.onChainEncryptionText }
        return parser.destination ?? ""
    }

    private func matchedDestinationsFrom(_ payments: [Payment]) -> [Destination] {
        payments.flatMap { $0.destinations.filter { !$0.isEncrypted } }
    }

    private func toVerifyResult(_ payments: [Payment], _ verifyURL: String) -> VerifyResult {
        if payments.isEmpty {
            return VerifyResult(status: .unknown, verifyURL: verifyURL)
        }
        return VerifyResult(
            status: .match,
            payments: payments,
            matchedDestinations: matchedDestinationsFrom(payments),
            verifyURL: verifyURL
        )
    }

    private func buildVerifyURL(options: BrantaApiOptions?, paymentLookup: String, keys: [(String, String)] = []) -> String {
        let baseURL = resolvedBaseURL(defaults: defaultOptions, override: options).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "\(baseURL)/v2/verify/\(pathEscape(paymentLookup))" + urlFragment(for: keys)
    }
}

private func foldDescriptionIntoMetadata(_ payment: inout Payment) {
    guard let description = payment.description, !description.isEmpty else { return }
    var map: [String: Any] = [:]
    if let metadata = payment.metadata, !metadata.isEmpty,
       let data = metadata.data(using: .utf8),
       let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        map = parsed
    }
    if map["description"] == nil {
        map["description"] = description
    }
    guard JSONSerialization.isValidJSONObject(map),
          let data = try? JSONSerialization.data(withJSONObject: map),
          let encoded = String(data: data, encoding: .utf8) else {
        return
    }
    payment.metadata = encoded
    payment.description = nil
}

private func liftDescriptionFromMetadata(_ payment: inout Payment) {
    guard let metadata = payment.metadata, !metadata.isEmpty,
          let data = metadata.data(using: .utf8),
          let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let description = parsed["description"] as? String else {
        return
    }
    payment.description = description
}
