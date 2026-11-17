import Foundation

struct QRDestination {
    var value: String
    /// Rail this value belongs to. Set for bitcoin and ERC-681 transfers.
    var type: DestinationType?
    /// Visible address that participates in the secret-key swap check.
    var secretKey: Bool = false
}

struct QRParser {
    var destinations: [QRDestination] = []
    var onChainEncryptionText = ""
    var onChainEncryptionSecret = ""
    /// Destination types this scan may decrypt.
    /// ERC-681 sets one type from the chain id and token contract.
    /// Bitcoin sets `bitcoinAddress`.
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
        if schemeLower == "ethereum" {
            guard let transfer = parseERC681(text) else {
                destinations.append(QRDestination(value: text, type: nil))
                return
            }
            destinations.append(QRDestination(value: transfer.address, type: transfer.type, secretKey: true))
            expectedSecretKeyTypes = [transfer.type]
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
    // A "?" after the "#" belongs to the fragment, not the query.
    let beforeFragment = text.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? text
    guard let colon = beforeFragment.firstIndex(of: ":") else { return "" }
    let after = beforeFragment[beforeFragment.index(after: colon)...]
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

private func isASCIIDigit(_ byte: UInt8) -> Bool {
    byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
}

private func isASCIIHex(_ byte: UInt8) -> Bool {
    isASCIIDigit(byte)
        || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f"))
        || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "F"))
}

/// Path of an `ethereum:` URI, without scheme, query, or fragment. One leading slash is dropped.
private func erc681Path(_ text: String) -> [UInt8] {
    var bytes = Array(text.utf8)
    if let colon = bytes.firstIndex(of: UInt8(ascii: ":")) {
        bytes = Array(bytes[(colon + 1)...])
    }
    if let cut = bytes.firstIndex(where: { $0 == UInt8(ascii: "?") || $0 == UInt8(ascii: "#") }) {
        bytes = Array(bytes[..<cut])
    }
    if bytes.first == UInt8(ascii: "/") {
        bytes.removeFirst()
    }
    return bytes
}

/// `0x` or `0X` followed by 40 hex digits.
private func isEVMAddress(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    guard bytes.count == 42, bytes[0] == UInt8(ascii: "0"),
          bytes[1] == UInt8(ascii: "x") || bytes[1] == UInt8(ascii: "X") else { return false }
    return bytes[2...].allSatisfy(isASCIIHex)
}

/// ERC-681 token transfer. Chain id and contract select one destination type.
/// The deposit address is the `address` query param.
private func parseERC681(_ text: String) -> (type: DestinationType, address: String)? {
    let path = erc681Path(text)
    guard let at = path.firstIndex(of: UInt8(ascii: "@")) else { return nil }
    let contract = Array(path[..<at])
    // The contract prefix is a lowercase `0x`, then 40 hex digits.
    guard contract.count == 42, contract[0] == UInt8(ascii: "0"), contract[1] == UInt8(ascii: "x"),
          contract[2...].allSatisfy(isASCIIHex) else { return nil }
    let suffix = Array("/transfer".utf8)
    let rest = Array(path[(at + 1)...])
    guard rest.count > suffix.count, rest.suffix(suffix.count).elementsEqual(suffix) else { return nil }
    let chainBytes = Array(rest.dropLast(suffix.count))
    guard !chainBytes.isEmpty, chainBytes.allSatisfy(isASCIIDigit) else { return nil }
    let digits = chainBytes.drop { $0 == UInt8(ascii: "0") }
    // No supported chain id has more than 15 digits.
    guard digits.count <= 15 else { return nil }
    let chainID = digits.isEmpty ? 0 : (Int(String(decoding: digits, as: UTF8.self)) ?? -1)
    guard chainID >= 0,
          let type = evmTokenType(chainID: chainID, contract: String(decoding: contract, as: UTF8.self)) else { return nil }
    guard let address = parseQuery(extractQuery(text))["address"], isEVMAddress(address) else { return nil }
    return (type, address)
}
