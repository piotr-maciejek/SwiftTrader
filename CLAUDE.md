## Build & Run (no Xcode)

```bash
# Build
xcodebuild -scheme SwiftTrader -destination 'platform=macOS' -derivedDataPath build build

# Run
open build/Build/Products/Debug/SwiftTrader.app
```

Requires jforex-server running on `localhost:8080` — see `../jforex-server/`.

## Architecture

MVVM with Swift concurrency (Swift 6.0, macOS 15+, Xcode 26):

- **Models/** — `CandleBar` (OHLCV), `Position` (open order with P&L), `Account` (balance/equity/margin), `TradingSnapshot` (WebSocket message), `TabState` (workspace serialization), `AppSettings`, `VisualOrderState` (visual order with per-instrument SL/TP/amount), `NewsItem` (economic calendar event)
- **ViewModels/** — `AuthViewModel` (LIVE PIN/captcha auth flow), `ChartViewModel` (per-tab chart state), `TradingViewModel` (shared, account-wide positions and visual orders), `WorkspaceViewModel` (tabs, panels, news feed)
- **Views/** — Canvas-based chart (`ChartView`), zoom/scroll (`ChartTransform`), native mouse events (`ScrollWheelView`), visual order box with draggable SL/TP and amount controls, economic calendar table (`RightPanel`), positions table (`BottomPanel`)
- **Services/** — `AuthService` (auth status, captcha, PIN submission), `MarketDataCoordinator` (history + live bars), `TradingCoordinator` (orders + live positions), `NewsCoordinator` (live economic calendar via WebSocket), `WorkspaceStateService` (tab/panel persistence via UserDefaults); each coordinator wraps an actor (REST) and a Sendable class (WebSocket)

The coordinator pattern abstracts data sources. ViewModels never talk to services directly. `TradingViewModel` is shared across all tabs (positions are account-wide, not per-chart).

## Adding files to the Xcode project

This project uses explicit file references in `project.pbxproj`. New `.swift` files must be added manually:

1. Add a `PBXFileReference` entry
2. Add a `PBXBuildFile` entry
3. Add the file ref to the appropriate `PBXGroup`
4. Add the build file to the `PBXSourcesBuildPhase`

## Server connection

- REST: `GET /api/v1/auth/status`, `GET /api/v1/auth/captcha`, `POST /api/v1/auth/pin`
- REST: `GET /api/v1/instruments`, `GET /api/v1/history`, `POST /api/v1/orders`, `DELETE /api/v1/orders/{label}`, `GET /api/v1/orders`, `GET /api/v1/news`
- WebSocket: `ws://localhost:8080/ws/bars?instrument=EURUSD&period=ONE_MIN`, `ws://localhost:8080/ws/positions`, `ws://localhost:8080/ws/news`
- Default port 8080, configurable via Settings popover
- Local HTTP permitted via `NSAllowsLocalNetworking` in `Info.plist`
