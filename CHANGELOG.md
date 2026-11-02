# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [4.0.0] - 2026-11-02

### Removed
- **BREAKING:** `PrivacyMode`. Every destination is encrypted. On-chain lookups need `branta_id` and `branta_secret`. bolt11, Ark, and silent payments still resolve from the value.
- **BREAKING:** `PaymentBuilder.setZK()` and `Destination.isZk`. `addPayment` assigns `Destination.id`. Guardrail still receives `zk: true` and `zk_id`.
- **BREAKING:** `getPayments` and `getPaymentsByQRCode`. Call `verify` for a QR scan or a paste.
- **BREAKING:** `verify` returns `VerifyResult` with `status` of `match`, `unknown`, `tampered`, or `incomplete`. A swapped address is `tampered`. `payments` is present only on `match`. `PaymentsResult` is gone.
- **BREAKING:** `DestinationType` values for bolt12, LNURL, a Lightning address, and tether. `DestinationType` is what `addPayment` accepts: `bitcoin_address`, `bolt11`, `ark_address`, `silent_payment`.
- **BREAKING:** `BrantaClientOptions` is `BrantaApiOptions`. `baseURL` is `environment`. `BrantaServerBaseURL` is `BrantaEnvironment`. `defaultAPIKey` is `apiKey`.
- **BREAKING:** `Payment.btcPayServerPluginVersion` and `Payment.defaultValue()`.
- **BREAKING:** `Destination.zkID` is `Destination.id`. Guardrail still receives `zk_id`.

### Added
- `verify` status `incomplete` when the lookup does not finish (5xx, 429, or no network). A 404 is `unknown`.

### Fixed
- An unset `TTL` is left off the POST. Guardrail then applies its 7-day default. A posted `0` is stored for 30 seconds.
- `verify` of a bolt11, Ark, or silent payment is `unknown` unless a destination of that type decrypts. A different plaintext is `tampered`. Case differences still match.
- `verify` of `branta_id` / `branta_secret` with no payable destination is `unknown` and does not look the record up.
- A raw on-chain address, including `tb1` and `bcrt1`, is `unknown` and is not fetched.
- `addPayment` encrypts a copy of the caller `Payment`. A failed post leaves that object plaintext, so a retry encrypts the original destination again.
- `verifyURL` fragment names and values are percent-encoded, so a crafted id or secret cannot add parameters.
- A tab, line feed, or carriage return in a QR is stripped before the destination is typed, and a repeated query key keeps the first value.

### Changed
- `setDescription` writes `metadata.description`. The SDK does not POST or GET Guardrail plaintext `description`. After metadata decrypt, `Payment.description` is lifted from `metadata.description`.
- This release matches `@branta-ops/branta` 4.0.5.

## [3.2.4] - 2026-10-29

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
