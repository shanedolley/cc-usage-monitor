# Shared API fixtures

Real JSON responses captured from the Anthropic OAuth endpoints (`/api/oauth/profile` and `/api/oauth/usage`) and the token refresh endpoint. Both the macOS and Windows test suites read these as the single source of truth for the API contract, so the two apps parse the same shapes and stay in parity.

## Why they live here

The endpoints are undocumented and may change. Keeping one committed set of fixtures means a captured response is updated in one place, and both apps' version-tolerant parsing tests run against the same data. It also documents the exact field names and nesting the apps depend on.

## Rules

- Capture from a real account, then **scrub all PII and secrets** before committing: remove `access_token`, `refresh_token`, the account `full_name`, `email`, and `uuid`. Replace them with obvious placeholders.
- Name files by endpoint and case, for example `usage-live.json`, `usage-credits-disabled.json`, `profile-max-20x.json`.
- Keep them minimal: enough to exercise a parsing path, no more.
