# Branta Swift SDK

If you are implementing this SDK in a consumer project, product rules (send vs receive, `match` / `unknown` / `tampered`, parent platforms) live in the [developer docs](https://developer.branta.pro). `README.md` is the Swift package: install, constructor, and samples.

## Commands

```bash
swift test
BRANTA_RUN_INTEGRATION=1 BRANTA_API_KEY=… swift test --filter MultiRailRoundTripTests
```

Live write/lookup tests run only when `BRANTA_RUN_INTEGRATION=1` (and `BRANTA_API_KEY` for POST).

## Layout

Public API is whatever the `Branta` module exposes: `BrantaService`, `PaymentBuilder`, `BrantaApiOptions`, `BrantaEnvironment`, `DestinationType`, `VerifyStatus`, `VerifyResult`, `AddPaymentResult`, payment models, and `BrantaPaymentError`.

Do **not** make public: `BrantaClient`, `QRParser`, AES helpers, rail-family lists (`secretKeyURIFamilies`, per-family arrays), or `isSecretKeyAddressType`. Prefer package-internal (`internal`) for those. `PublicAPITests` uses `import Branta` (not `@testable`) to lock the consumer surface.

| File | Role |
|------|------|
| `Service.swift` | Encrypt/decrypt orchestration around HTTP. Do not export the client. |
| `Client.swift` | Raw HTTP. Timeouts map transport failures to incomplete on GET. |
| `DestinationTypes.swift` | `DestinationType`, verify statuses, rail families (internal). |
| `Options.swift` | Environment, `BrantaApiOptions`, errors. |
| `Models.swift` | Payment / destination / result types. |
| `WireCoding.swift` | JSON encode/decode. |
| `QRParser.swift` | QR / URI parsing (internal). |
| `PaymentBuilder.swift` | Fluent `Payment` construction. |
| `Encoding.swift` | Hash, percent-encoding, HMAC, origin checks. |
| `AES.swift` | Crypto primitives (internal). |

## Key behaviors

- `verify` is the only lookup. A raw on-chain address (including bare `0x`) is `unknown` and does not GET. `addPayment` encrypts a copy.
- `DestinationType` is only what `addPayment` accepts: bitcoin, bolt11, ark, silent payment, and the stablecoin rails (`usdt_polygon` … `usdc_solana`). No `usdc_ton` yet. Stablecoin rails use chain URIs (`pol:`, `eth:`, `bsc:`, `tron:`, `ton:`, `sol:`) with `branta_id` / `branta_secret`. Token is on `matchedDestinations[].type`, not the URI scheme.
- `verify` `match` includes `matchedDestinations` — wallets send from that list.
- `tampered` and `incomplete` are statuses. Do not throw them. Logo-domain mismatches still throw `BrantaPaymentError`. Malformed GET bodies and network/timeouts are `incomplete`.
- `hmacSecret` is deprecated — shared `apiKey` + `setChildPlatform` is the parent-platform path.
- Acronym casing follows Swift (`verifyURL`, `isAPIKeyValid`). Error type is `BrantaPaymentError` (not `Exception`).
