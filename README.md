# SwiftTrader

> **Work in progress** -- actively under development.

A native macOS forex trading client built with SwiftUI. Designed as a fast, lightweight alternative to Dukascopy's Java-based JForex platform -- no JVM overhead, instant startup, smooth 60fps chart rendering.

Connects to [jforex-server](https://github.com/piotr-maciejek/jforex-server) for market data and order execution via the Dukascopy Broker API.

## Philosophy

SwiftTrader is calibrated for **price action trading**. Clean charts, no indicator bloat -- just candles, price levels, and fast order execution. If you want 47 oscillators stacked on top of each other, this isn't the tool for you.

## Features

- **Canvas-based candlestick chart** with drag-to-scroll, mouse wheel zoom, and live streaming
- **Multiple tabs** -- each with independent instrument and timeframe
- **Market orders** -- manual mode (popover with SL/TP fields) or one-click mode (automatic SL/TP from previous candle at 1:3 R:R)
- **Positions panel** -- open positions with live P&L and close button
- **Auto-reconnect** -- handles server restarts gracefully

## Running

Requires [jforex-server](https://github.com/piotr-maciejek/jforex-server) running on `localhost:8080`.

```bash
xcodebuild -scheme SwiftTrader -destination 'platform=macOS' -derivedDataPath build build
open build/Build/Products/Debug/SwiftTrader.app
```

Or open `SwiftTrader.xcodeproj` in Xcode and run (⌘R).
