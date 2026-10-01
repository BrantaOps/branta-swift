# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [3.2.2] - 2026-10-01

### Added

- Initial release of the Branta Swift SDK for iOS 15+ and macOS 12+.
- Feature-parity port of `branta-kotlin` 3.2.2 (and `branta-go`, `branta-js`, `branta-dotnet`, `branta-python`, `branta-rust`, `branta-dart`).
- `BrantaService` with `getPaymentsByQRCode`, `getPayments`, `addPayment`, and `isAPIKeyValid`.
- `PaymentBuilder` with ZK support, metadata encryption, and child platform tagging.
- `QRParser` for `bitcoin:` / `lightning:` URIs and plain-text values, including BIP-21 query decoding.
- AES-256-GCM encryption. Wire format matches the other SDKs: SHA-256 key, 12-byte nonce, base64(nonce || ciphertext || tag). Deterministic nonces use HMAC-SHA256.
- Zero-knowledge destinations for Bitcoin addresses, BOLT-11, Ark, and silent payments.
- Metadata DEK-envelope encryption.
- `PrivacyMode.strict` (default) and `PrivacyMode.loose`.
- HMAC-SHA256 request signing for parent-platform flows.
- Same-origin checks for platform, parent, and child logo URLs.
- `getPaymentsByQRCode` rejects a QR whose visible Bitcoin address does not match the address decrypted from `branta_id` / `branta_secret`.
- Swift Package Manager and CocoaPods.
