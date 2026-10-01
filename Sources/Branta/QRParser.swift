import Foundation

struct QRDestination {
    var value: String
    var type: DestinationType?
}

struct QRParser {
    var destinations: [QRDestination] = []
    var onChainEncryptionText: String?
    var onChainEncryptionSecret: String?

    var destination: String? { destinations.first?.value }
    var destinationType: DestinationType? { destinations.first?.type }

    init(_ qrText: String) {
        let text = qrText.trimmingCharacters(in: .whitespacesAndNewlines)
        let scheme = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map { String($0).lowercased() } ?? ""

        if scheme == "bitcoin" || scheme == "lightning" {
            if let address = Self.extractAddress(text) {
                destinations.append(QRDestination(value: address, type: Self.destinationType(of: text)))
            }
            let query = text.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().first.map(String.init) ?? ""
            let params = Self.parseQuery(query)
            onChainEncryptionText = params["branta_id"]
            onChainEncryptionSecret = params["branta_secret"]
            if let lightning = params["lightning"] {
                destinations.append(QRDestination(value: lightning, type: Self.detectPlainTextType(lightning)))
            }
            if let bolt12 = params["bolt12"] {
                destinations.append(QRDestination(value: bolt12, type: Self.detectPlainTextType(bolt12)))
            }
            if let ark = params["ark"] {
                destinations.append(QRDestination(value: ark, type: Self.detectPlainTextType(ark)))
            }
            if let silent = params["silent_payment"] {
                destinations.append(QRDestination(value: silent, type: Self.detectPlainTextType(silent)))
            }
        } else if text.contains(":") {
            destinations.append(QRDestination(value: text, type: nil))
        } else {
            destinations.append(QRDestination(value: text, type: Self.detectPlainTextType(text)))
        }
    }

    func isOnChainZK() -> Bool {
        onChainEncryptionText != nil && onChainEncryptionSecret != nil
    }

    private static func extractAddress(_ text: String) -> String? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let afterColon = text.index(after: colon)
        let address: String
        if let question = text[afterColon...].firstIndex(of: "?") {
            address = String(text[afterColon..<question])
        } else {
            address = String(text[afterColon...])
        }
        return address.isEmpty ? nil : address
    }

    private static func destinationType(of text: String) -> DestinationType? {
        let scheme = text.split(separator: ":", maxSplits: 1).first.map { String($0).lowercased() } ?? ""
        if scheme == "bitcoin" { return .bitcoinAddress }
        if scheme == "lightning" {
            guard let dest = extractAddress(text) else { return nil }
            if isBolt11(dest) { return .bolt11 }
            if dest.lowercased().hasPrefix("lno") { return .bolt12 }
            if dest.lowercased().hasPrefix("lnurl") { return .lnURL }
        }
        return nil
    }

    private static func parseQuery(_ query: String) -> [String: String] {
        guard !query.isEmpty else { return [:] }
        var params: [String: String] = [:]
        for param in query.split(separator: "&", omittingEmptySubsequences: true) {
            guard let eq = param.firstIndex(of: "=") else { continue }
            let key = javaURLDecode(String(param[..<eq])).lowercased()
            let value = javaURLDecode(String(param[param.index(after: eq)...]))
            params[key] = value
        }
        return params
    }

    static func detectPlainTextType(_ value: String) -> DestinationType? {
        if isBolt11(value) { return .bolt11 }
        if value.lowercased().hasPrefix("lno") { return .bolt12 }
        if value.lowercased().hasPrefix("lnurl") { return .lnURL }
        if isArk(value) { return .arkAddress }
        if isSilentPayment(value) { return .silentPayment }
        if value.range(of: "^0x[0-9a-fA-F]{40}$", options: .regularExpression) != nil { return .tetherAddress }
        if value.count == 34 && value.hasPrefix("T") { return .tetherAddress }
        if value.range(of: "^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", options: .regularExpression) != nil { return .lnAddress }
        if value.hasPrefix("1") || value.hasPrefix("3") || value.lowercased().hasPrefix("bc1") {
            return .bitcoinAddress
        }
        return nil
    }
}
