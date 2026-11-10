# Branta Swift SDK

Swift SDK for the [Branta](https://developer.branta.pro) V2 API. For native iOS and macOS apps.

Use `verify` on send and `addPayment` on receive. Status handling and parent platforms are in the [developer docs](https://developer.branta.pro).

## Requirements

- iOS 15 or macOS 12
- Swift 5.9

## Install

Swift Package Manager, in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/BrantaOps/branta-swift.git", from: "4.0.0"),
],
targets: [
    .target(name: "YourApp", dependencies: ["Branta"]),
]
```

Or in Xcode: File → Add Package Dependencies → `https://github.com/BrantaOps/branta-swift.git`, from version 4.0.0.

## Send

```swift
import Branta

let service = BrantaService(options: BrantaApiOptions(
    environment: .production // Staging everywhere else
))

let result = try await service.verify(input) // scanned QR or pasted text

switch result.status {
case .match:
    // Show the card for result.payments[0]. Link it to result.verifyURL.
    // For pol: rails, token is on result.matchedDestinations[i].type
    // (.usdtPolygon / .usdcPolygon) — do not infer it from pol:.
case .unknown:
    // Not in Branta. Show nothing.
case .tampered:
    // Destination was altered. Warn. Do not show a verified card.
case .incomplete:
    // 5xx, 429, or unreachable. Tell the user. Do not treat this as unknown.
}
```

A logo on the wrong origin throws. Do not treat that as `unknown`.

On-chain Bitcoin needs a `bitcoin:` URI with `branta_id` and `branta_secret`. Polygon EVM rails (`usdt_polygon`, `usdc_polygon`) need a `pol:` URI with the same params — token is on `matchedDestinations[].type`, not the `pol:` scheme. bolt11, Ark, and silent payments resolve from the value. A bare address (including bare `0x`) is `unknown`.

A 404 is `unknown`. A 5xx, a 429, or no network is `incomplete`.

## Receive

```swift
let service = BrantaService(options: BrantaApiOptions(
    environment: .production,
    apiKey: "<api-key>"
))

let payment = PaymentBuilder()
    .setDescription("Invoice #12345")
    .addDestination("bc1q…", type: .bitcoinAddress)
    // Polygon: pass .usdtPolygon / .usdcPolygon explicitly — bare 0x is not auto-detected.
    // .addDestination("0x…", type: .usdtPolygon)
    .setTTL(600)
    .build()

let added = try await service.addPayment(payment)
```

`addPayment` encrypts a copy. The `Payment` you pass in stays plaintext, so a failed post can be retried with the same value.

Store `added.secret` with the invoice. Put `branta_id` and `branta_secret` on the invoice QR (`bitcoin:…` or `pol:…`). `added.verifyURL` is the link for the wallet.

A parent platform with one shared key sets `apiKey` on the service and calls `setChildPlatform(name:logoURL:logoLightURL:)` for each payment. That is the path for new parent platforms. The deprecated per-client HMAC path is in the developer docs.

## Destination types

`addPayment` accepts `bitcoinAddress`, `bolt11`, `arkAddress`, `silentPayment`, `usdtPolygon`, and `usdcPolygon`. Bitcoin and Polygon addresses use the secret `addPayment` returns. bolt11, Ark, and silent payments use a key derived from the lowercased value, so the same input always produces the same lookup token. Pass Polygon types explicitly — a bare `0x` address is not auto-detected.

## Development

```bash
swift test
BRANTA_RUN_INTEGRATION=1 swift test --filter IntegrationTests
```

## Publishing

1. Add a changelog entry and bump the version in the Installation section.
2. Tag the release `v4.0.0` (the `v` prefix). Swift Package Manager resolves `from: "4.0.0"` from that tag.
3. Push the tag: `git push origin v4.0.0`

## Responsible Disclosure

Found critical bugs/vulnerabilities? Please email them to support@branta.pro. Thanks!
