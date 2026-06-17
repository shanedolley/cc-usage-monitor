# Claude Code Usage Monitor

A small desktop app that shows your Claude Code account usage at a glance and warns you before you hit a limit. It reads the OAuth token Claude Code already stores, polls the Anthropic usage endpoints every 60 seconds, shows the numbers in the menu bar or system tray as donut rings, and fires a notification when a metric crosses a threshold you set.

This repository holds two native implementations of the same product, one per platform.

## Platforms

| Platform | Stack | Status | Setup |
|----------|-------|--------|-------|
| macOS | Swift, SwiftUI, AppKit | Shipping | [`macos/install.md`](macos/install.md) |
| Windows | C#, WPF, .NET 8 | In development | `windows/` (see PRD) |

The two apps share an API contract and behavior, not code: macOS and Windows use different languages and toolchains, so each is a native implementation that follows the same design.

## Repository layout

```
macos/            Swift menu bar app (xcodegen + Xcode)
windows/          .NET 8 WPF system-tray app (in development)
shared/fixtures/  Probe JSON shared by both test suites
docs/             Repository documentation
```

## Releases

Each platform versions and releases independently using a tag prefix (`macos-vX.Y.Z`, `windows-vX.Y.Z`). See [`docs/release-tagging.md`](docs/release-tagging.md).

## What it reads

The app reads, and on token refresh rewrites, Claude Code's own credential store (the macOS Keychain, or `%USERPROFILE%\.claude\.credentials.json` on Windows). It never asks for a password and sends data only to your own Anthropic account. Per-platform detail lives in each app's `install.md`.
