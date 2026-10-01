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
    private let defaultOptions: BrantaClientOptions?
    private let client: BrantaClienting
    private let aes: AESEncrypting
    private let secretGenerator: SecretGenerating

    public init(options: BrantaClientOptions? = nil) {
        self.defaultOptions = options
        self.client = BrantaClient(defaultOptions: options)
        self.aes = AESEncryptionService()
        self.secretGenerator = GuidSecretGenerator()
    }

    init(
        options: BrantaClientOptions?,
        client: BrantaClienting,
        aes: AESEncrypting,
        secretGenerator: SecretGenerating
    ) {
        self.defaultOptions = options
        self.client = client
        self.aes = aes
        self.secretGenerator = secretGenerator
    }

    public func getPaymentsByQRCode(_ qrText: String, options: BrantaClientOptions? = nil) async throws -> PaymentsResult {
        let parser = QRParser(qrText)
        if parser.isOnChainZK() {
            let additional = parser.destinations.compactMap { destination -> String? in
                hashZKType(of: destination.value) == nil ? nil : destination.value
            }
            let onChain = parser.destinations.first { $0.type == .bitcoinAddress }?.value
            return try await getPaymentsForZK(
                lookupValue: parser.onChainEncryptionText ?? "",
                encryptionKey: parser.onChainEncryptionSecret,
                additionalHashValues: additional,
                expectedOnChainAddress: onChain,
                options: options
            )
        }

        guard let destination = parser.destination else {
            return PaymentsResult(payments: [], verifyURL: try buildVerifyURL(options: options, paymentLookup: ""))
        }

        if resolvedPrivacy(defaults: defaultOptions, override: options) == .strict && hashZKType(of: destination) == nil {
            return PaymentsResult(payments: [], verifyURL: try buildVerifyURL(options: options, paymentLookup: destination))
        }

        return try await getPayments(destination, destinationEncryptionKey: nil, options: options)
    }

    public func getPayments(
        _ destinationValue: String,
        destinationEncryptionKey: String? = nil,
        options: BrantaClientOptions? = nil
    ) async throws -> PaymentsResult {
        let hashType = hashZKType(of: destinationValue)
        if hashType == nil && destinationEncryptionKey == nil && resolvedPrivacy(defaults: defaultOptions, override: options) == .strict {
            throw BrantaPaymentError(message: "PrivacyMode.Strict does not permit plain-text lookups for this destination type.")
        }

        let normalized = hashType == nil ? destinationValue : destinationValue.lowercased()
        var lookupValue = destinationValue
        if hashType != nil {
            lookupValue = try aes.encrypt(value: normalized, secret: normalizedHash(normalized), deterministicNonce: true)
        }

        var payments = try await client.getPayments(destinationValue: lookupValue, options: options)
        if payments.isEmpty && hashType != nil && resolvedPrivacy(defaults: defaultOptions, override: options) != .strict {
            lookupValue = normalized
            payments = try await client.getPayments(destinationValue: lookupValue, options: options)
        }

        var keys: [(String, String)] = []
        for payment in payments {
            try decryptDestinations(
                payment: payment,
                destinationValue: normalized,
                encryptionKey: destinationEncryptionKey,
                hashZKType: hashType,
                keys: &keys,
                expectedOnChainAddress: nil
            )
        }
        return PaymentsResult(payments: payments, verifyURL: try buildVerifyURL(options: options, paymentLookup: lookupValue, keys: keys))
    }

    public func addPayment(_ payment: Payment, options: BrantaClientOptions? = nil) async throws -> AddPaymentResult {
        if resolvedPrivacy(defaults: defaultOptions, override: options) == .strict && payment.destinations.contains(where: { !$0.isZk }) {
            throw BrantaPaymentError(message: "PrivacyMode.Strict requires all destinations to be ZK; one or more destinations have isZk = false.")
        }

        var dek: String?
        if payment.metadata != nil && payment.destinations.contains(where: { $0.isZk }) {
            dek = secretGenerator.generate()
            payment.metadata = try aes.encrypt(value: payment.metadata ?? "", secret: dek ?? "", deterministicNonce: false)
        }

        let secret = secretGenerator.generate()
        var encryptedToKey: [String: String] = [:]

        for destination in payment.destinations {
            guard destination.isZk else { continue }
            if destination.type == .bitcoinAddress {
                destination.value = try aes.encrypt(
                    value: destination.value,
                    secret: secret,
                    deterministicNonce: secretGenerator.deterministicNonce
                )
                encryptedToKey[destination.value] = secret
                if let dek {
                    destination.encryptedDek = try aes.encrypt(value: dek, secret: secret, deterministicNonce: false)
                }
            } else {
                guard let hashType = hashZKType(of: destination.value) else {
                    throw BrantaPaymentError(message: "destination type '\(destination.type?.kotlinName ?? "null")' does not support ZK")
                }
                _ = hashType
                let normalized = destination.value.lowercased()
                let key = normalizedHash(normalized)
                destination.value = try aes.encrypt(value: normalized, secret: key, deterministicNonce: true)
                encryptedToKey[destination.value] = key
                if let dek {
                    destination.encryptedDek = try aes.encrypt(value: dek, secret: key, deterministicNonce: false)
                }
            }
        }

        guard let response = try await client.postPayment(payment, options: options) else {
            throw BrantaPaymentError(message: "No payment returned from server.")
        }

        var keys: [(String, String)] = []
        for destination in response.destinations {
            if let zkID = destination.zkID, let key = encryptedToKey[destination.value] {
                if !keys.contains(where: { $0.0 == zkID }) {
                    keys.append((zkID, key))
                }
            }
        }

        let primary = payment.destinations.first?.value ?? ""
        return AddPaymentResult(
            payment: response,
            secret: secret,
            verifyURL: try buildVerifyURL(options: options, paymentLookup: primary, keys: keys)
        )
    }

    public func isAPIKeyValid(options: BrantaClientOptions? = nil) async throws -> Bool {
        try await client.isAPIKeyValid(options: options)
    }

    private func getPaymentsForZK(
        lookupValue: String,
        encryptionKey: String?,
        additionalHashValues: [String],
        expectedOnChainAddress: String?,
        options: BrantaClientOptions?
    ) async throws -> PaymentsResult {
        let payments = try await client.getPayments(destinationValue: lookupValue, options: options)
        var keys: [(String, String)] = []
        for payment in payments {
            try decryptDestinations(
                payment: payment,
                destinationValue: lookupValue,
                encryptionKey: encryptionKey,
                hashZKType: nil,
                keys: &keys,
                expectedOnChainAddress: expectedOnChainAddress
            )
            for value in additionalHashValues {
                decryptHashZKDestinations(payment: payment, plainValue: value, keys: &keys)
            }
        }
        return PaymentsResult(payments: payments, verifyURL: try buildVerifyURL(options: options, paymentLookup: lookupValue, keys: keys))
    }

    private func decryptDestinations(
        payment: Payment,
        destinationValue: String,
        encryptionKey: String?,
        hashZKType: DestinationType?,
        keys: inout [(String, String)],
        expectedOnChainAddress: String?
    ) throws {
        for destination in payment.destinations {
            destination.isEncrypted = destination.isZk
            guard destination.isZk else { continue }

            if destination.type == .bitcoinAddress {
                guard let encryptionKey else { continue }
                let decrypted: String
                do {
                    decrypted = try aes.decrypt(encryptedValue: destination.value, secret: encryptionKey)
                } catch {
                    continue
                }
                if let expectedOnChainAddress, !addressesMatch(decrypted, expectedOnChainAddress) {
                    throw BrantaPaymentError(
                        message: "The Bitcoin address in the QR code does not match the address verified by Branta. The QR code may have been tampered with.",
                        reason: .tampered
                    )
                }
                destination.value = decrypted
                destination.isEncrypted = false
                putIfAbsent(zkID: destination.zkID, key: encryptionKey, into: &keys)
                tryDecryptMetadata(payment: payment, destination: destination, keyUsed: encryptionKey)
            } else if let hashZKType, destination.type == hashZKType {
                let key = normalizedHash(destinationValue)
                do {
                    destination.value = try aes.decrypt(encryptedValue: destination.value, secret: key)
                    destination.isEncrypted = false
                    putIfAbsent(zkID: destination.zkID, key: key, into: &keys)
                    tryDecryptMetadata(payment: payment, destination: destination, keyUsed: key)
                } catch {
                    continue
                }
            }
        }
    }

    private func decryptHashZKDestinations(payment: Payment, plainValue: String, keys: inout [(String, String)]) {
        guard let hashType = hashZKType(of: plainValue) else { return }
        let key = normalizedHash(plainValue)
        for destination in payment.destinations {
            guard destination.isZk, destination.type == hashType else { continue }
            do {
                destination.value = try aes.decrypt(encryptedValue: destination.value, secret: key)
                destination.isEncrypted = false
                putIfAbsent(zkID: destination.zkID, key: key, into: &keys)
                tryDecryptMetadata(payment: payment, destination: destination, keyUsed: key)
            } catch {
                continue
            }
        }
    }

    private func tryDecryptMetadata(payment: Payment, destination: Destination, keyUsed: String) {
        guard let encryptedDek = destination.encryptedDek, payment.metadata != nil, !payment.isMetadataDecrypted else { return }
        do {
            let dek = try aes.decrypt(encryptedValue: encryptedDek, secret: keyUsed)
            payment.metadata = try aes.decrypt(encryptedValue: payment.metadata ?? "", secret: dek)
            payment.isMetadataDecrypted = true
        } catch {
            return
        }
    }

    private func putIfAbsent(zkID: String?, key: String, into keys: inout [(String, String)]) {
        guard let zkID, !keys.contains(where: { $0.0 == zkID }) else { return }
        keys.append((zkID, key))
    }

    private func buildVerifyURL(options: BrantaClientOptions?, paymentLookup: String, keys: [(String, String)] = []) throws -> String {
        let baseURL = try resolvedBaseURL(defaults: defaultOptions, override: options)
        var url = "\(baseURL)/v2/verify/\(javaURLEncode(paymentLookup))"
        if !keys.isEmpty {
            url += urlFragment(for: keys)
        }
        return url
    }
}
