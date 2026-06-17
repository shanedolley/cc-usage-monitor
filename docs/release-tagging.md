# Release Tagging Conventions

This repository holds two apps that ship on their own schedules. Git tags and GitHub Releases use a per-platform prefix so the two version lines never collide and every release reads unambiguously.

## Tag format

```
<platform>-v<major>.<minor>.<patch>
```

- `<platform>` is `macos` or `windows`.
- The version is [Semantic Versioning](https://semver.org): `MAJOR.MINOR.PATCH`.

Examples:

| Tag | Meaning |
|-----|---------|
| `macos-v1.3.0` | macOS app, version 1.3.0 |
| `windows-v1.0.0` | Windows app, first release |
| `macos-v1.3.1` | macOS patch release |

The two lines advance independently. `macos-v2.0.0` and `windows-v1.0.0` can coexist; the numbers carry no relationship across platforms.

## Why prefixes

GitHub shows all tags and Releases for the repository on one page. Without a prefix, a `v1.0.0` from each app would clash and a reader could not tell which platform a release belongs to. The prefix makes every tag self-describing and lets release automation filter by platform.

## Creating a release

1. Land all changes for the release on `main`.
2. Tag the exact commit with the prefixed, SemVer tag:
   ```
   git tag macos-v1.3.0
   git push origin macos-v1.3.0
   ```
3. Create the GitHub Release from that tag. Title it with the platform and version (for example, "macOS 1.3.0"), and attach the platform's artifact: the signed `.app` (or its installer) for macOS, the signed `.exe` installer for Windows.

## Release titles

Title each GitHub Release "<Platform> <version>" (for example, "Windows 1.0.0") so the Releases list stays readable when both platforms appear together.

## Continuous integration

Per-platform workflows key off the prefix and the changed paths:

- A `macos-v*` tag, or a change under `macos/` or `shared/`, runs the macOS build and tests.
- A `windows-v*` tag, or a change under `windows/` or `shared/`, runs the Windows build and tests.

This keeps each platform's pipeline independent while a change under `shared/` re-runs both.
