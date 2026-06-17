# Windows app (.NET 8, WPF)

The native Windows implementation of the Claude Code Usage Monitor. In development.

It mirrors the macOS app's behavior: two donut rings in the system tray (current session and weekly all-models), a detail window with every metric, 60-second polling, token refresh with write-back, a notification rules engine, and Windows toast alerts on threshold crossings. It reads and atomically rewrites Claude Code's token file at `%USERPROFILE%\.claude\.credentials.json`.

## Planned layout

```
src/         WPF app and services
tests/       Unit tests (xUnit), driven by shared/fixtures
installer/   Inno Setup script, Authenticode-signed, x64 + ARM64
```

## Status

No code yet. The design, requirements, and the Phase 1 spike gate are documented in the project's local brainstorm notes (not tracked in this repository). Build and packaging instructions will land in `windows/install.md` once the app exists.
