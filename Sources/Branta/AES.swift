import CryptoKit
import Foundation

protocol AESEncrypting {
    func encrypt(value: String, secret: String, deterministicNonce: Bool) throws -> String
    func decrypt(encryptedValue: String, secret: String) throws -> String
}

struct AESError: Error, Equatable {
    let message: String
}

enum AESEncryption {
    static func encrypt(value: String, secret: String, deterministicNonce: Bool = false) throws -> String {
        do {
            let keyData = Data(SHA256.hash(data: Data(secret.utf8)))
            let key = SymmetricKey(data: keyData)
            let nonce = try makeNonce(value: value, key: key, deterministic: deterministicNonce)
            let sealed = try AES.GCM.seal(Data(value.utf8), using: key, nonce: nonce)
            guard let combined = sealed.combined else {
                throw AESError(message: "Encryption failed: missing ciphertext")
            }
            return combined.base64EncodedString()
        } catch let error as AESError {
            throw error
        } catch {
            throw AESError(message: "Encryption failed: \(error.localizedDescription)")
        }
    }

    static func decrypt(encryptedValue: String, secret: String) throws -> String {
        guard let encryptedData = Data(base64Encoded: encryptedValue) else {
            throw AESError(message: "Decryption failed: invalid base64")
        }
        if encryptedData.count < 28 {
            throw AESError(message: "Invalid encrypted data: too short")
        }
        do {
            let keyData = Data(SHA256.hash(data: Data(secret.utf8)))
            let key = SymmetricKey(data: keyData)
            let sealed = try AES.GCM.SealedBox(combined: encryptedData)
            let clear = try AES.GCM.open(sealed, using: key)
            guard let text = String(data: clear, encoding: .utf8) else {
                throw AESError(message: "Decryption failed: invalid utf-8")
            }
            return text
        } catch let error as AESError {
            throw error
        } catch {
            throw AESError(message: "Decryption failed: \(error.localizedDescription)")
        }
    }

    private static func makeNonce(value: String, key: SymmetricKey, deterministic: Bool) throws -> AES.GCM.Nonce {
        if deterministic {
            let code = HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: key)
            return try AES.GCM.Nonce(data: Data(code.prefix(12)))
        }
        return AES.GCM.Nonce()
    }
}

struct AESEncryptionService: AESEncrypting {
    func encrypt(value: String, secret: String, deterministicNonce: Bool) throws -> String {
        try AESEncryption.encrypt(value: value, secret: secret, deterministicNonce: deterministicNonce)
    }

    func decrypt(encryptedValue: String, secret: String) throws -> String {
        try AESEncryption.decrypt(encryptedValue: encryptedValue, secret: secret)
    }
}
