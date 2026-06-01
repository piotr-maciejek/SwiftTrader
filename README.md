# SwiftTrader

> **Work in progress** -- actively under development.

A native macOS forex trading client built with SwiftUI. Designed as a fast, lightweight alternative to Dukascopy's Java-based JForex platform -- no JVM overhead, instant startup, smooth 60fps chart rendering.

Runs **standalone** by default: talks Dukascopy's wire protocol directly via the in-tree `DukascopyClient` Swift package -- no JVM, no server. Everything runs natively in this mode: market data, order execution (market/limit/stop, close, cancel, modify SL/TP), positions, account, the economic calendar, and closed-trade history. Optional **server mode** routes those through [jforex-server](https://github.com/piotr-maciejek/jforex-server) instead.

## Philosophy

SwiftTrader is calibrated for **price action trading**. Clean charts, no indicator bloat -- just candles, price levels, and fast order execution. If you want 47 oscillators stacked on top of each other, this isn't the tool for you.

## Screenshots

![Candlestick chart with market session overlays](screenshots/chart.png)

![Economic calendar panel](screenshots/calendar.png)

![Currency correlation grid](screenshots/correlation.png)

## Features

- **Standalone mode** (default) -- native SRP6 connection to Dukascopy, no JVM, no server. Fully self-contained: market data, orders (market/limit/stop, close, cancel, modify SL/TP), positions, account, news/economic calendar, and closed-trade history all run over the wire. Deep history via per-period `.bi5` downloads; single shared on-disk cache across all timeframes; multi-account login (demo + live) with passwords stored as SHA-1 hashes in the macOS Keychain
- **Canvas-based candlestick chart** with drag-to-scroll, mouse wheel zoom, and live streaming
- **Multiple tabs** -- each with independent instrument and timeframe
- **Visual order entry** -- click Buy/Sell to place a visual order box on the chart with draggable SL/TP lines, adjustable position size (+/- buttons), live R:R and pip calculations. Entry price tracks the market in real-time. Confirm or cancel directly on the chart (or Enter/Escape). Multiple visual orders supported across different instruments
- **Positions panel** -- open positions with live P&L, draggable SL/TP modification, and close button
- **Economic calendar** -- right panel (⌥⌘0) showing today's economic events from Dukascopy with country, actual/expected/previous values color-coded (green = beat, red = miss), streamed live via WebSocket
- **Currency correlation screens** -- click a currency button (e.g. "EUR", "USD") in the chart header to open a 6-chart grid showing all pairs containing that currency, with synchronized timeframes
- **Market session overlays** -- Tokyo, London, and New York sessions drawn as colored rectangles on the chart, with dashed lines marking actual stock exchange open/close times. Forex session hours match TradingView conventions; DST-aware via IANA timezone database. Togglable via the clock icon in the chart header
- **Auto-reconnect** -- handles server restarts gracefully

## Running

Standalone mode needs no server -- just build and run:

```bash
xcodebuild -scheme SwiftTrader -destination 'platform=macOS' -derivedDataPath build build
open build/Build/Products/Debug/SwiftTrader.app
```

On first launch, add a Dukascopy demo or live account in the login sheet. Subsequent launches reuse the saved credentials -- the sheet just asks you to confirm the account, no password re-entry.

For server mode, also run [jforex-server](https://github.com/piotr-maciejek/jforex-server) on `localhost:8080`, then flip Settings → Data provider → Server (restart required).

Or open `SwiftTrader.xcodeproj` in Xcode and run (⌘R).
