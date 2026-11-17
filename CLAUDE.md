# Branta Swift SDK

Swift package `Branta`. Consumers (wallets, platforms, parent platforms) call `BrantaService` to look up or post payments to Branta's V2 API. `README.md` is the install, constructor, and samples guide.

## Behavior contract

What `verify` returns and how ERC-681 is parsed: [Status rules](https://developer.branta.pro/setup/send/status-rules). Which rails encrypt with what key: [Encryption](https://developer.branta.pro/setup/receive/encryption). Send handling is on [Send](https://developer.branta.pro/setup/send), and the type list on [Destination types](https://developer.branta.pro/destination-types). Do not restate them here. Change the docs first, then the SDK.

Invariants that break silently. Check them before you change `verify` or `addPayment`:

- A raw on-chain address (including `tb1` / `bcrt1` / bare `0x`) is `unknown` and does not GET.
- A swapped address is `tampered`. `unknown`, `tampered`, and `incomplete` are returned, never thrown.
- The token is `matchedDestinations[].type`, never the URI scheme.
- A logo-domain mismatch throws. Every other lookup failure is a status.
- `addPayment` encrypts a copy and leaves the caller's `Payment` unchanged.
- Keep parity with every 4.x Branta SDK. A public method added or changed here is mirrored in each of them.

## Swift specifics

- A logo-domain mismatch throws `BrantaPaymentError` (not `Exception`).
- Acronym casing follows Swift: `verifyURL`, `isAPIKeyValid`.
- `DestinationType` is only what `addPayment` accepts. It also includes `usdt_tron`, `usdt_ton`, `usdt_solana`, and `usdc_solana`. They can be posted but no URI verifies them, and they are not on the public Destination types page. There is no `usdc_ton`.
- `hmacSecret` is deprecated. A shared `apiKey` plus `setChildPlatform` is the parent-platform path.

## Commands

```bash
swift test
BRANTA_RUN_INTEGRATION=1 BRANTA_API_KEY=… swift test --filter MultiRailRoundTripTests
```

Live write/lookup tests run only when `BRANTA_RUN_INTEGRATION=1` (and `BRANTA_API_KEY` for POST).

## Layout

Public API is whatever the `Branta` module exposes: `BrantaService`, `PaymentBuilder`, `BrantaApiOptions`, `BrantaEnvironment`, `DestinationType`, `VerifyStatus`, `VerifyResult`, `AddPaymentResult`, payment models, and `BrantaPaymentError`.

Do **not** make public: `BrantaClient`, `QRParser`, AES helpers, the EVM rail table (`evmTokenRails`, `evmTokenType`), or `isSecretKeyAddressType`. Prefer package-internal (`internal`) for those. `PublicAPITests` uses `import Branta` (not `@testable`) to lock the consumer surface.

| File | Role |
|------|------|
| `Service.swift` | Encrypt/decrypt orchestration around HTTP. Do not export the client. |
| `Client.swift` | Raw HTTP. Timeouts map transport failures to incomplete on GET. |
| `DestinationTypes.swift` | `DestinationType`, verify statuses, and the EVM rail table (internal). |
| `Options.swift` | Environment, `BrantaApiOptions`, errors. |
| `Models.swift` | Payment / destination / result types. |
| `WireCoding.swift` | JSON encode/decode. |
| `QRParser.swift` | QR / URI parsing (internal). |
| `PaymentBuilder.swift` | Fluent `Payment` construction. |
| `Encoding.swift` | Hash, percent-encoding, HMAC, origin checks. |
| `AES.swift` | Crypto primitives (internal). |
