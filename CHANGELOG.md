# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Security

- `getPaymentsByQRCode` now requires every payable instruction in a QR code to match a decrypted destination. A swapped address with a rewritten `branta_secret`, an added `lightning` / `ark` / `silent_payment` / `sp` leg, or a conflicting `bc=` / `tb=` no longer comes back as verified; the result has no payments. On-chain addresses from the path, `bc=`, and `tb=` must all agree, otherwise the call throws `tampered`.
- `bolt12`, `lno=`, `pay=`, and LNURL instructions cannot be bound to a decrypted destination, so the QR returns no payments (no lookup is made). `verifyUrl` is still returned.
- `tb1` and `bcrt1` addresses are compared case-insensitively, like `bc1`.

## [3.2.3] - 2026-10-28

### Added

- Recognize signet and regtest Ark addresses (`tark1`) as `ark_address`, alongside mainnet `ark1`. Strict-mode hash-ZK lookup and registration treat them the same way as `ark1`.

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
- Swift Package Manager.
