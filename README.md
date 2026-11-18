# Branta Swift SDK

Swift SDK for [Branta](https://developer.branta.pro). For native iOS and macOS apps.

Status handling and parent platforms are in the [developer docs](https://developer.branta.pro).

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
    environment: .production
))

let result = try await service.verify(input) // scanned QR or pasted text

switch result.status {
case .match:
    // Show the card for result.payments[0]. Link it to result.verifyURL.
    // For EVM stablecoins, token is on result.matchedDestinations[i].type. Pay from that list.
case .unknown:
    // Not in Branta. Show nothing.
case .tampered:
    // Destination was altered. Warn. Do not show a verified card.
case .incomplete:
    // Branta could not complete the check. Tell the user. Do not block send.
}
```

A logo on the wrong origin throws. Do not treat that as `unknown`.

Rules for each status: [Status rules](https://developer.branta.pro/setup/send/status-rules). Supported types: [Destination types](https://developer.branta.pro/destination-types).

## Receive

```swift
let service = BrantaService(options: BrantaApiOptions(
    environment: .production,
    apiKey: "<api-key>"
))

let payment = PaymentBuilder()
    .setDescription("Invoice #12345")
    .addDestination("bc1q…", type: .bitcoinAddress)
    .setTTL(600)
    .build()

let added = try await service.addPayment(payment)
// Store added.secret with the invoice. Put branta_id and branta_secret on the QR.
// Link the sender to added.verifyURL.
```

`addPayment` accepts the types on [Destination types](https://developer.branta.pro/destination-types). Pass the type for stablecoins. A bare address is not auto-detected. `usdtTron`, `usdtTon`, `usdtSolana`, and `usdcSolana` also encrypt and post, but no URI verifies them.

[Security](SECURITY.md)
