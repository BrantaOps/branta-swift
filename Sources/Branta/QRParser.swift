import Foundation

struct QRDestination {
    var value: String
    /// Known rail type when the scheme or payload names one (e.g. bitcoin). Not set for `pol:`.
    var type: DestinationType?
    /// Visible address that participates in the secret-key swap check.
    var secretKey: Bool = false
}

struct QRParser {
    var destinations: [QRDestination] = []
    var onChainEncryptionText = ""
    var onChainEncryptionSecret = ""
    /// Destination types `verify` may bind for this QR's scheme (match-if-any).
    /// Set from the URI scheme — not from a token stamped on the address.
    var expectedSecretKeyTypes: [DestinationType] = []
    /// A payable instruction this SDK cannot bind to a decrypted destination.
    var hasUnverifiableInstruction = false

    var destination: String? { destinations.first?.value }
    var destinationType: DestinationType? { destinations.first?.type }

    init(_ qrText: String) {
        let text = normalizeQRText(qrText)
        guard let scheme = uriScheme(text) else {
            destinations.append(QRDestination(value: text, type: detectPlainTextType(text)))
            return
        }

        let schemeLower = scheme.lowercased()
        if schemeLower == "pol" {
            let destValue = extractDestination(text)
            destinations.append(QRDestination(value: destValue, type: nil, secretKey: true))
            expectedSecretKeyTypes = polygonEvmDestinationTypes
            let query = parseQuery(extractQuery(text))
            onChainEncryptionText = query["branta_id"] ?? ""
            onChainEncryptionSecret = query["branta_secret"] ?? ""
            return
        }

        guard schemeLower == "bitcoin" || schemeLower == "lightning" else {
            destinations.append(QRDestination(value: text, type: nil))
            return
        }

        let destValue = extractDestination(text)
        let destType: DestinationType? = schemeLower == "bitcoin" ? .bitcoinAddress : lightningSchemeType(destValue)
        destinations.append(QRDestination(
            value: destValue,
            type: destType,
            secretKey: destType == .bitcoinAddress
        ))
        if !destValue.isEmpty && destType != .bitcoinAddress && derivedKeyType(of: destValue) == nil {
            hasUnverifiableInstruction = true
        }

        let query = parseQuery(extractQuery(text))
        onChainEncryptionText = query["branta_id"] ?? ""
        onChainEncryptionSecret = query["branta_secret"] ?? ""
        addBindable(query, key: "lightning", onChain: false)
        addBindable(query, key: "ark", onChain: false)
        addBindable(query, key: "silent_payment", onChain: false)
        addBindable(query, key: "bc", onChain: true)
        addBindable(query, key: "tb", onChain: true)
        addBindable(query, key: "sp", onChain: false)
        if let bolt12 = query["bolt12"], !bolt12.isEmpty {
            hasUnverifiableInstruction = true
        }
        if let lno = query["lno"], !lno.isEmpty {
            hasUnverifiableInstruction = true
        }
        if let pay = query["pay"], !pay.isEmpty {
            hasUnverifiableInstruction = true
        }

        if destinations.contains(where: { $0.secretKey }) {
            expectedSecretKeyTypes = [.bitcoinAddress]
        }
    }

    func isOnChainZK() -> Bool {
        !onChainEncryptionText.isEmpty && !onChainEncryptionSecret.isEmpty
    }

    private mutating func addBindable(_ query: [String: String], key: String, onChain: Bool) {
        guard let value = query[key] else { return }
        let type: DestinationType? = onChain ? .bitcoinAddress : detectPlainTextType(value)
        if !value.isEmpty && !onChain && derivedKeyType(of: value) == nil {
            hasUnverifiableInstruction = true
            return
        }
        destinations.append(QRDestination(value: value, type: type, secretKey: onChain))
    }
}

func detectPlainTextType(_ value: String) -> DestinationType? {
    if isBolt11(value) { return .bolt11 }
    if isArk(value) { return .arkAddress }
    if isSilentPayment(value) { return .silentPayment }
    let lower = value.lowercased()
    if value.hasPrefix("1") || value.hasPrefix("3")
        || lower.hasPrefix("bc1") || lower.hasPrefix("tb1") || lower.hasPrefix("bcrt1") {
        return .bitcoinAddress
    }
    return nil
}

func normalizeQRText(_ qrText: String) -> String {
    let trimmed = qrText.trimmingCharacters(in: .whitespacesAndNewlines)
    var bytes = Array(trimmed.utf8)
    while let first = bytes.first, first <= 0x20 {
        bytes.removeFirst()
    }
    while let last = bytes.last, last <= 0x20 {
        bytes.removeLast()
    }
    bytes.removeAll { $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }
    return String(bytes: bytes, encoding: .utf8) ?? trimmed
}

private func uriScheme(_ text: String) -> String? {
    let bytes = Array(text.utf8)
    guard let first = bytes.first, isASCIIAlpha(first) else { return nil }
    var end = 1
    while end < bytes.count {
        let byte = bytes[end]
        if isASCIIAlphanumeric(byte) || byte == UInt8(ascii: "+") || byte == UInt8(ascii: "-") || byte == UInt8(ascii: ".") {
            end += 1
            continue
        }
        break
    }
    guard end < bytes.count, bytes[end] == UInt8(ascii: ":") else { return nil }
    return String(bytes: bytes[..<end], encoding: .utf8)
}

private func extractDestination(_ text: String) -> String {
    guard let colon = text.firstIndex(of: ":") else { return "" }
    let after = text[text.index(after: colon)...]
    if let question = after.firstIndex(of: "?") {
        return String(after[..<question])
    }
    return String(after)
}

private func extractQuery(_ text: String) -> String {
    guard let colon = text.firstIndex(of: ":") else { return "" }
    let after = text[text.index(after: colon)...]
    guard let question = after.firstIndex(of: "?") else { return "" }
    return String(after[after.index(after: question)...])
}

private func parseQuery(_ query: String) -> [String: String] {
    var params: [String: String] = [:]
    for pair in query.split(separator: "&", omittingEmptySubsequences: false) {
        if pair.isEmpty { continue }
        let raw = String(pair)
        let keyPart: String
        let valuePart: String
        if let eq = raw.firstIndex(of: "=") {
            keyPart = String(raw[..<eq])
            valuePart = String(raw[raw.index(after: eq)...])
        } else {
            keyPart = raw
            valuePart = ""
        }
        if keyPart.isEmpty { continue }
        let key = pathUnescape(keyPart).lowercased()
        if params[key] != nil { continue }
        params[key] = pathUnescape(valuePart)
    }
    return params
}

private func lightningSchemeType(_ dest: String) -> DestinationType? {
    isBolt11(dest) ? .bolt11 : nil
}
