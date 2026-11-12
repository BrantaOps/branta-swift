import CryptoKit
import Foundation

func normalizedHash(_ value: String) -> String {
    let digest = SHA256.hash(data: Data(value.lowercased().utf8))
    return digest.map { String(format: "%02X", $0) }.joined()
}

func urlFragment(for keys: [(String, String)]) -> String {
    if keys.isEmpty { return "" }
    return "#" + keys.map { "k-\(fragmentEscape($0.0))=\(fragmentEscape($0.1))" }.joined(separator: "&")
}

/// Percent-encodes everything except unreserved characters, matching .NET `Uri.EscapeDataString`.
/// This encodes `+`, `/`, and `=`, which appear in base64 ciphertext lookup values.
func pathEscape(_ value: String) -> String {
    percentEncode(value, safe: isPathUnreserved)
}

/// Percent-encodes with the `encodeURIComponent` set: everything except
/// ALPHA / DIGIT / "-" / "_" / "." / "!" / "~" / "*" / "'" / "(" / ")".
func fragmentEscape(_ value: String) -> String {
    percentEncode(value, safe: isFragmentSafe)
}

func pathUnescape(_ value: String) -> String {
    var out: [UInt8] = []
    let bytes = Array(value.utf8)
    var index = 0
    while index < bytes.count {
        if bytes[index] == UInt8(ascii: "%") {
            if index + 2 >= bytes.count { return value }
            let hex = String(bytes: [bytes[index + 1], bytes[index + 2]], encoding: .ascii) ?? ""
            guard let byte = UInt8(hex, radix: 16) else { return value }
            out.append(byte)
            index += 3
        } else {
            out.append(bytes[index])
            index += 1
        }
    }
    return String(bytes: out, encoding: .utf8) ?? value
}

func hmacSHA256Hex(secret: String, message: String) -> String {
    let key = SymmetricKey(data: Data(secret.utf8))
    let code = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
    return code.map { String(format: "%02x", $0) }.joined()
}

func origin(of urlString: String) -> String? {
    guard let components = URLComponents(string: urlString),
          let scheme = components.scheme,
          let host = components.host,
          !scheme.isEmpty, !host.isEmpty else {
        return nil
    }
    if let port = components.port {
        return "\(scheme)://\(host):\(port)".lowercased()
    }
    return "\(scheme)://\(host)".lowercased()
}

private func percentEncode(_ value: String, safe: (UInt8) -> Bool) -> String {
    var out = ""
    for byte in value.utf8 {
        if safe(byte) {
            out.append(Character(UnicodeScalar(byte)))
        } else {
            out.append(String(format: "%%%02X", byte))
        }
    }
    return out
}

private func isPathUnreserved(_ byte: UInt8) -> Bool {
    if isASCIIAlphanumeric(byte) { return true }
    switch byte {
    case UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "~"):
        return true
    default:
        return false
    }
}

private func isFragmentSafe(_ byte: UInt8) -> Bool {
    if isASCIIAlphanumeric(byte) { return true }
    switch byte {
    case UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."),
         UInt8(ascii: "!"), UInt8(ascii: "~"), UInt8(ascii: "*"),
         UInt8(ascii: "'"), UInt8(ascii: "("), UInt8(ascii: ")"):
        return true
    default:
        return false
    }
}

func isASCIIAlpha(_ byte: UInt8) -> Bool {
    (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
        || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
}

func isASCIIAlphanumeric(_ byte: UInt8) -> Bool {
    isASCIIAlpha(byte) || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
}
