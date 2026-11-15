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

Or in Xcode: File → Add Package Dependencies → `https://github.com/BrantaOps/branta-swift.git`, from version 4.4.0.

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

On-chain Bitcoin needs a `bitcoin:` URI with `branta_id` and `branta_secret`. EVM stablecoins (USDT and USDC on Ethereum, Polygon, BNB Smart Chain, Base, and Arbitrum) need an ERC-681 `ethereum:<token-contract>@<chain-id>/transfer?address=<deposit>` URI with the same params. The chain id and token contract select the destination type, and `uint256` is not part of the match. `pol:`, `eth:`, `bsc:`, `tron:`, `ton:`, and `sol:` do not verify. bolt11, Ark, and silent payments resolve from the value. A bare address (including bare `0x`) is `unknown`. Tron, TON, and Solana rails encrypt on `addPayment` but have no verify URI.

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
    // Stablecoin: pass the type explicitly — bare addresses are not auto-detected.
    // .addDestination("0x…", type: .usdtEthereum)
    .setTTL(600)
    .build()

let added = try await service.addPayment(payment)
```

`addPayment` encrypts a copy. The `Payment` you pass in stays plaintext, so a failed post can be retried with the same value.

Store `added.secret` with the invoice. Put `branta_id` and `branta_secret` on the invoice QR (`bitcoin:…` or the ERC-681 `ethereum:…` URI). `added.verifyURL` is the link for the wallet.

A parent platform with one shared key sets `apiKey` on the service and calls `setChildPlatform(name:logoURL:logoLightURL:)` for each payment. That is the path for new parent platforms. The deprecated per-client HMAC path is in the developer docs.

## Destination types

`addPayment` accepts `bitcoinAddress`, `bolt11`, `arkAddress`, `silentPayment`, `usdtPolygon`, `usdcPolygon`, `usdtEthereum`, `usdcEthereum`, `usdtBsc`, `usdcBsc`, `usdtBase`, `usdcBase`, `usdtArbitrum`, `usdcArbitrum`, `usdtTron`, `usdtTon`, `usdtSolana`, and `usdcSolana`. Bitcoin and stablecoin addresses use the secret `addPayment` returns. bolt11, Ark, and silent payments use a key derived from the lowercased value, so the same input always produces the same lookup token. Pass stablecoin types explicitly — a bare address (including bare `0x`) is not auto-detected.

## Development

```bash
swift test
BRANTA_RUN_INTEGRATION=1 swift test --filter IntegrationTests
```

## Publishing

1. Add a changelog entry and bump the version in the Installation section.
2. Tag the release `v4.4.0` (the `v` prefix). Swift Package Manager resolves `from: "4.4.0"` from that tag.
3. Push the tag: `git push origin v4.4.0`

## Responsible Disclosure

Found critical bugs/vulnerabilities? Please email them to support@branta.pro. Thanks!
