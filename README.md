# Branta Swift SDK

Swift SDK for the Branta V2 API — payment destination lookup and registration with zero-knowledge encryption support. For native iOS and macOS apps.

# Requirements

- iOS 15 or macOS 12
- Swift 5.9

# Installation

Swift Package Manager, in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/BrantaOps/branta-swift.git", from: "3.2.2"),
],
targets: [
    .target(name: "YourApp", dependencies: ["Branta"]),
]
```

Or in Xcode: File → Add Package Dependencies → `https://github.com/BrantaOps/branta-swift.git`, from version 3.2.2.

CocoaPods:

```ruby
pod 'Branta', '~> 3.2.2'
```

# Integration Guide

If you are an AI agent implementing this SDK, follow the steps below exactly. If you are a developer, use this as a reference for the recommended integration patterns.

**1. Ask which side(s) of a payment they are implementing:**
- **Send side** — the flow for outbound payments (e.g. a wallet scanning a QR code).
- **Receive side** — the flow for receiving payment (e.g. a checkout or POS). You post destinations (ZK-encrypted) to Branta so wallets can verify them.
- **Both** — some apps do both. Implement each side independently.

If they are on the receive side, ask one follow-up:
- **Platform** — single-tenant, one API key.
- **Parent Platform** — multi-tenant, manages multiple child platforms. Two variants:
  - **Shared key (Recommended)** — one API key for all children, no HMAC secret needed; tag the child per-payment with `setChildPlatform(name:logoURL:logoLightURL:)`. Default to this unless there's a specific reason for separate per-child keys.
  - **Per-client keys** — each child has its own API key, and the parent signs every request with an HMAC secret to prove it originated from the parent; scope requests per-call. Use only if each child needs an independent, separately-revocable API key.

**2. Follow the matching Quick Start section below.**

**3. Apply these rules:**

General (all types):
- Always use `PrivacyMode.strict`. Never switch to `loose` unless there is no QR scanner and ZK is impossible.
- Never call `BrantaClient` directly — always go through `BrantaService`.
- For `baseURL`: use `.production` only in production environments. Use `.staging` everywhere else — including local development, CI, and staging/test environments.

Send side (wallets):
- Prefer `getPaymentsByQRCode` over `getPayments` — it handles multi-value ZK QR payloads correctly.
- Only fall back to `getPayments` for copy/paste flows where there is no QR code.
- If `payments` is empty or an error is thrown, render nothing. Never show an error or "not verified" message.
- When `result.payments` is non-empty, display: the platform logo, the platform name (`payment.platform`), and the payment description (`payment.description`). Only render description when non-empty. Make the verification card a clickable link to `result.verifyURL` — do not display the raw URL.
- For the platform logo, use `payment.platformLogoURL` on dark backgrounds and `payment.platformLogoLightURL` on light backgrounds.
- Optionally display `payment.parentPlatform?.logoURL` / `payment.parentPlatform?.logoLightURL` as a small secondary badge (e.g. corner icon). This is not required.

Receive side (platforms):
- Always call `setZK()` on the `PaymentBuilder` before calling `addPayment`. Plain-text destinations are rejected in `strict` mode.
- Store the `secret` returned by `addPayment` alongside the invoice — it is required to reconstruct the verify URL.

Receive side (parent platforms — per-client keys), in addition to the platform rules:
- Include `hmacSecret` in `BrantaClientOptions` but omit `defaultAPIKey` at service construction.
- Pass per-call `BrantaClientOptions` with each child's API key to scope requests.

Receive side (parent platforms — shared key), in addition to the platform rules:
- Include `defaultAPIKey` in `BrantaClientOptions`. Do not include `hmacSecret`.
- Call `setChildPlatform(name:logoURL:logoLightURL:)` on the builder to tag each payment with the child's branding.

# Quick Start

## For Wallets

Wallets use `PrivacyMode.strict`. Two flows:

- **QR scan**: call `getPaymentsByQRCode` with the raw QR text.
- **Copy/paste**: call `getPayments` with the pasted text. Plain-text on-chain addresses won't return results in strict mode; self-encrypted types (bolt11, ark, silent payment) work.

```swift
import Branta

let service = BrantaService(options: BrantaClientOptions(
    baseURL: .production,
    privacy: .strict
))

do {
    let result = isQRCode
        ? try await service.getPaymentsByQRCode(input)
        : try await service.getPayments(input)

    if result.payments.isEmpty {
        // Not found — show nothing. Address not known to Branta, not necessarily malicious.
        return
    }

    // Render result.payments and result.verifyURL
} catch {
    // Swallow errors — never surface a lookup failure to the user.
}
```

### No-QR-Code Flows

When QR scanning is not available:

**Option 1 — Keep strict mode (no code changes)**

Only self-encrypted types (bolt11, ark, silent payment) return results. Plain-text on-chain addresses silently return empty from `getPaymentsByQRCode`, and `getPayments` throws.

**Option 2 — Opt-in loose mode (Recommended)**

Add a user-facing setting. Only switch when the user explicitly opts in:

```swift
let options = userOptedInToOnChainVerification
    ? BrantaClientOptions(privacy: .loose)
    : nil

let result = try await service.getPayments(input, options: options)
```

**Option 3 — Always loose mode**

```swift
let service = BrantaService(options: BrantaClientOptions(
    baseURL: .production,
    privacy: .loose
))
```

## For Platforms

```swift
let service = BrantaService(options: BrantaClientOptions(
    baseURL: .production,
    defaultAPIKey: "<api-key>",
    privacy: .strict
))
```

```swift
let payment = PaymentBuilder()
    .setDescription("Invoice #1234")
    .addDestination("1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa", type: .bitcoinAddress)
    .setZK()
    .setTTL(600)
    .build()

let result = try await service.addPayment(payment)
// result.secret — store alongside the invoice; needed to reconstruct verifyURL
// result.verifyURL — display to the payer
```

## For Parent Platforms

Choose a variant based on key structure. Only the per-client keys variant signs requests with HMAC — shared key needs none.

<details>
<summary>Shared key — one API key covers all children (Recommended)</summary>

```swift
let service = BrantaService(options: BrantaClientOptions(
    baseURL: .production,
    defaultAPIKey: "<shared-api-key>",
    privacy: .strict
))
```

```swift
let payment = PaymentBuilder()
    .addDestination("1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa", type: .bitcoinAddress)
    .setZK()
    .setChildPlatform(name: "ChildBrand", logoURL: "https://example.com/logo.png")
    .build()

let result = try await service.addPayment(payment)
```

</details>

<details>
<summary>Per-client keys — each child has its own API key</summary>

```swift
let service = BrantaService(options: BrantaClientOptions(
    baseURL: .production,
    hmacSecret: "<hmac-secret>",
    privacy: .strict
))
```

```swift
let payment = PaymentBuilder()
    .addDestination("1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa", type: .bitcoinAddress)
    .setZK()
    .build()

let result = try await service.addPayment(
    payment,
    options: BrantaClientOptions(defaultAPIKey: "<child-api-key>")
)
```

</details>

# Privacy

`PrivacyMode` controls whether plain-text on-chain lookups are allowed.

| Value | Behavior |
|-------|----------|
| `strict` | Only ZK (zero-knowledge / encrypted) lookups are permitted. `getPayments` throws `BrantaPaymentError` for plain addresses; `getPaymentsByQRCode` returns an empty list. `addPayment` requires all destinations to have `isZk = true`. |
| `loose` | Both plain and ZK lookups are allowed. No restrictions enforced. |

# BrantaService

The primary API.

**Prefer `getPaymentsByQRCode` for integrations.** It parses the raw QR text and correctly resolves multiple ZK values in a single scan.

```swift
func getPaymentsByQRCode(_ qrText: String, options: BrantaClientOptions?) async throws -> PaymentsResult
func getPayments(_ destinationValue: String, destinationEncryptionKey: String?, options: BrantaClientOptions?) async throws -> PaymentsResult
func addPayment(_ payment: Payment, options: BrantaClientOptions?) async throws -> AddPaymentResult
func isAPIKeyValid(options: BrantaClientOptions?) async throws -> Bool
```

`PaymentsResult` contains the list of matching `payments` and the `verifyURL` to display — `verifyURL` is always returned, even when `payments` is empty.

`AddPaymentResult` contains the `payment` response, the `secret` encryption key, and the `verifyURL`.

# Publishing

1. Bump `s.version` in `Branta.podspec` and add a changelog entry.
2. Tag the release `v3.2.2` (the `v` prefix). Swift Package Manager resolves `from: "3.2.2"` from that tag. CocoaPods uses the same tag via the podspec.
3. Push the tag: `git push origin v3.2.2`
4. CocoaPods trunk, once, from a machine registered with `pod trunk register`:

```bash
pod trunk push Branta.podspec
```

# Tests

```bash
swift test
```

Live calls to staging and production run with the suite. Set `BRANTA_SKIP_INTEGRATION=1` to skip them.

# Responsible Disclosure

Found critical bugs/vulnerabilities? Please email them to support@branta.pro. Thanks!
