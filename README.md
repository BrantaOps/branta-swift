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
    .package(url: "https://github.com/BrantaOps/branta-swift.git", from: "4.4.0"),
],
targets: [
    .target(name: "YourApp", dependencies: ["Branta"]),
]
```

Or in Xcode: File → Add Package Dependencies → `https://github.com/BrantaOps/branta-swift.git`.

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
    // For EVM stablecoins, token is on result.matchedDestinations[i].type
    // (e.g. .usdcBase). Pay from that list.
case .unknown:
    // Not in Branta. Show nothing.
case .tampered:
    // Destination was altered. Warn. Do not show a verified card.
case .incomplete:
    // 5xx, 429, or unreachable. Tell the user. Do not treat this as unknown.
}
```

A logo on the wrong origin throws. Do not treat that as `unknown`.

Pass the scanned or pasted text to `verify`. A Bitcoin or EVM stablecoin lookup needs `branta_id` and `branta_secret` in the URI. bolt11, Ark, and silent payments resolve from the value. A bare address is `unknown`. The full rules are on [Status rules](https://developer.branta.pro/setup/send/status-rules), and supported chains and contracts are on [Destination types](https://developer.branta.pro/destination-types).

A 404 is `unknown`. 5xx, 429, no network, a timeout, or a malformed GET body is `incomplete`.

## Receive

```swift
let service = BrantaService(options: BrantaApiOptions(
    environment: .production,
    apiKey: "<api-key>"
))

let payment = PaymentBuilder()
    .setDescription("Invoice #12345")
    .addDestination("bc1q…", type: .bitcoinAddress)
    // Stablecoin: pass the type explicitly — bare addresses are not auto-detected.
    // .addDestination("0x…", type: .usdtEthereum)
    .setTTL(600)
    .build()

let added = try await service.addPayment(payment)
```

`addPayment` encrypts a copy. The `Payment` you pass in stays plaintext, so a failed post can be retried with the same value.

Store `added.secret` with the invoice. Put `branta_id` and `branta_secret` on the invoice QR (`bitcoin:…` or the ERC-681 `ethereum:…` URI). `added.verifyURL` is the link for the wallet.

## Destination types

`addPayment` accepts the types on [Destination types](https://developer.branta.pro/destination-types), and [Encryption](https://developer.branta.pro/setup/receive/encryption) says which key each uses. `usdtTron`, `usdtTon`, `usdtSolana`, and `usdcSolana` also encrypt and post, but no URI verifies them.

## Development

```bash
swift test
BRANTA_RUN_INTEGRATION=1 swift test --filter IntegrationTests
```

[Security](SECURITY.md)
