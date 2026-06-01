## Build & Run (no Xcode)

```bash
# Build
xcodebuild -scheme SwiftTrader -destination 'platform=macOS' -derivedDataPath build build

# Run
open build/Build/Products/Debug/SwiftTrader.app
```

In **server mode** requires `jforex-server` on `localhost:8080` (see `../jforex-server/`).
In **standalone mode** no server is needed — SwiftTrader talks to Dukascopy directly via
the in-tree `Packages/DukascopyClient/` Swift package.

> Editing sources under `Packages/DukascopyClient/` requires a clean app rebuild
> (`rm -rf build` first); incremental `xcodebuild` won't recompile the local package.

## Modes

Picked at launch via Settings → Data provider; switching requires a restart so
subscriptions aren't torn down mid-flight.

- **Server** — market data + orders + news all go through `jforex-server`.
- **Standalone** (default since 2026-05) — `NativeMarketDataCoordinator` drives a
  `DukascopySession` directly, and `NativeTradingCoordinator` / `NativeNewsCoordinator`
  route orders and news over the same session, and `NativeTradeHistoryService` reads
  closed trades from it. Fully server-independent: market data, orders (market/limit/stop,
  close, cancel, modify SL/TP), the news/economic calendar and closed-trade history all
  work natively. Login sheet shows on every launch so the user confirms which account to
  use; saved password hashes are reused via the Keychain.

## Architecture

MVVM with Swift concurrency (Swift 6.0, macOS 15+, Xcode 26):

- **Packages/DukascopyClient/** — local Swift package implementing Dukascopy's wire
  protocol natively: SRP6 auth (`AuthClient`), TLS framing + heartbeat (`Transport`),
  candle subscribe + chunked history (`DukascopySession`), deep history via HTTPS
  `.bi5` downloads (`BulkHistoryClient`, LZMA via SWCompression), Java-properties
  parsing (`JavaPropertiesParser` for `history.server.url` out of the occasus blob),
  per-instrument pip values (`InstrumentPipValue`), account snapshot, order placement
  + position/account decode (`OrderMessages` — the desktop `ord.OrderGroupMessage`
  path, NOT the ignored `extapi`), and news/economic-calendar subscribe + decode
  (`NewsMessages`). Ships a CLI (`dukascopy-cli`) for protocol prototyping (incl.
  `submit`/`close`/`cancel`/`modify`/`news`). Reference: `PROTOCOL.md` inside the
  package.
- **Models/** — `CandleBar` (OHLCV), `Position` (open order with P&L), `Account`
  (balance/equity/margin), `TradingSnapshot` (WebSocket message), `TabState`
  (workspace serialization), `AppSettings` (incl. `dataProvider: DataProviderMode`),
  `VisualOrderState`, `NewsItem`, `DukascopyAccount`, `AccountStore` (saved
  standalone accounts in UserDefaults + Keychain).
- **ViewModels/** — `AuthViewModel` (server-mode PIN/captcha flow),
  `StandaloneAuthViewModel` (native session lifecycle, phase model mirrors
  `AuthViewModel`), `ChartViewModel` (per-tab chart state), `TradingViewModel`
  (shared, account-wide positions and visual orders), `WorkspaceViewModel`
  (tabs, panels, news feed; constructs the right coordinator per `dataProvider`).
- **Views/** — Canvas-based chart (`ChartView`), zoom/scroll (`ChartTransform`),
  native mouse events (`ScrollWheelView`), visual order box with draggable SL/TP
  and amount controls, economic calendar (`RightPanel`), positions
  (`BottomPanel`), `StandaloneLoginSheet` (account picker + add form),
  `NativePinSheet` (LIVE captcha/PIN, slice D).
- **Services/** — `AuthService` (server auth), `MarketDataCoordinator` (server
  history + live bars), `NativeMarketDataCoordinator` (parallel
  `MarketDataProviding` impl driving `DukascopySession`), `TradingCoordinator`
  (server-mode orders + live positions) and `NativeTradingCoordinator` (standalone
  orders/positions/account/spreads over the session — both conform to
  `TradingCoordinating`), `PnLConverter` (per-position P&L in the account currency
  with a pip fallback), `NewsCoordinator` (server-mode news/calendar WebSocket) and
  `NativeNewsCoordinator` (standalone news/calendar from Dukascopy's own feed — both
  conform to `NewsProviding`), `WorkspaceStateService` (tab/panel
  persistence), `KeychainStore` (SHA-1 password-hash storage),
  `CandleCache` + `DiskCandleCache` (shared in-memory + on-disk SCB1 packed
  binary, ~200k bars/key, lazy per-key load), `HistoryCoalescer` +
  `HistoryPrefetcher` (idle-gated background warm-up of 1H→2y + 1m→30d across
  subscribed pairs), `BarAggregator` (3m/5m/15m/30m from 1m, 4H/Daily from 1H —
  native mode aggregates 5m/15m/30m client-side because Dukascopy only stores
  1m/1H/Daily natively), `NYTradingCalendar` (FX session boundaries,
  weekend/holiday gap-skipping).

The coordinator pattern abstracts data sources. ViewModels never talk to
services directly. `TradingViewModel` is shared across all tabs (positions are
account-wide, not per-chart).

## Adding files to the Xcode project

This project uses explicit file references in `project.pbxproj`. New `.swift` files must be added manually:

1. Add a `PBXFileReference` entry
2. Add a `PBXBuildFile` entry
3. Add the file ref to the appropriate `PBXGroup`
4. Add the build file to the `PBXSourcesBuildPhase`

(Files inside `Packages/DukascopyClient/Sources/**` auto-glob — no `pbxproj` edits.)

## Server-mode connection

- REST: `GET /api/v1/auth/status`, `GET /api/v1/auth/captcha`, `POST /api/v1/auth/pin`
- REST: `GET /api/v1/instruments`, `GET /api/v1/history`, `POST /api/v1/orders`, `DELETE /api/v1/orders/{label}`, `GET /api/v1/orders`, `GET /api/v1/news`
- WebSocket: `ws://localhost:8080/ws/bars?instrument=EURUSD&period=ONE_MIN`, `ws://localhost:8080/ws/positions`, `ws://localhost:8080/ws/news`
- Default port 8080, configurable via Settings popover
- Local HTTP permitted via `NSAllowsLocalNetworking` in `Info.plist`

## Standalone-mode connection

- SRP6 auth to Dukascopy auth endpoint; binary-framed session over TLS
  (`Network.framework`), heartbeat-echoed every ~15s.
- Live tick / candle-subscribe + chunked history (`HistoryGroupMessage` routed by
  `requestId`, ordered by `messageOrder`, finished flag).
- Deep history via HTTPS `.bi5` downloads from `history.server.url` (parsed from
  the occasus settings blob delivered at auth). Records are 24-byte BE
  `(secOffset, open, close, low, high, volume)`, LZMA-alone container; pip scaling
  per-instrument (EURUSD 0.0001, JPY-quote 0.01, …). Only 1m / 1H / Daily are
  stored upstream; 5m/15m/30m/3m are aggregated client-side from 1m, 4H from 1H.
- Credentials: `login` + SHA-1 password hash in Keychain (plaintext never stored).
  Multiple accounts persisted in UserDefaults; the login sheet shows on every
  launch so the user explicitly confirms the account.
- Orders place natively via `ord.OrderGroupMessage` (market/limit/stop, close,
  cancel, modify SL/TP); the `extapi.Submit*` requests are silently ignored by the
  desktop server, so the `ord` path is the working one. News + economic calendar via
  the `msg.news` subscribe/decode path (the same feed JForex exposes). All over the
  same authenticated session.
- LIVE / non-whitelisted IPs need captcha/PIN via dual-SRP6 session
  (`NativePinSheet`) — implemented but not end-to-end verified (the test IPs have
  been whitelisted, so the server returns `checkPin=false` and skips it).
