# CLAUDE.md

Guidance for working in this repository.

## What this is

The Claude Code Usage Monitor: a desktop app that shows your Claude Code account usage at a glance and alerts you before you hit a limit. It reads the OAuth token Claude Code already stores, polls the Anthropic usage endpoints every five minutes, and shows the numbers in the menu bar (macOS) or system tray (Windows) as donut rings, with threshold notifications.

## Monorepo layout

This repository holds two native implementations of one product. They share an API contract and behavior, not code: macOS and Windows use different languages and toolchains, so each is a native app that follows the same design.

| Path | Contents |
|------|----------|
| `macos/` | Swift / SwiftUI / AppKit menu bar app (shipping) |
| `windows/` | C# / WPF / .NET 8 system-tray app (in development) |
| `shared/fixtures/` | Probe JSON shared by both test suites; scrub PII and tokens before committing |
| `docs/` | Repository documentation |

## Build and test

**macOS** (run from `macos/`):

```
cd macos
xcodegen generate
xcodebuild -project CCUsageMonitor.xcodeproj -scheme CCUsageMonitor -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO
```

`project.yml` is the source of truth; the `.xcodeproj` and `Info.plist` are generated and gitignored. Package, sign, and install a release with `macos/scripts/build-release.sh` (details in `macos/install.md`).

**Windows**: no code yet. The .NET app and its tests will live under `windows/`.

## Releases

Tag each platform independently with a prefix and SemVer: `macos-vX.Y.Z` and `windows-vX.Y.Z`. See `docs/release-tagging.md` for the full convention and the per-platform CI mapping.

## Local-only directories (never commit)

`docs/brainstorm/` and `.taskmaster/` are gitignored and live on the local machine only. They were purged from git history and must not be re-added to the repository.

## Conventions

- `.env.example` is an intentional template for future contributors; keep it.
- Stage specific files, never `git add .`.
- A change under `shared/` affects both apps; update and test both.
