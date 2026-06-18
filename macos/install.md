# Install CC Usage Monitor

CC Usage Monitor is a menu bar app that shows your Claude Code usage and alerts you when a metric crosses a threshold you set. It runs as a menu bar accessory: no Dock icon, and it keeps running after you close its window.

## Requirements

- macOS 14 or later.
- Claude Code signed in on this Mac. The app reads its credentials from the `Claude Code-credentials` Keychain item; it never asks you for a password.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) and the Xcode command line tools, to build from source.
- A self-signed code-signing certificate (see the next section). You create it once.

## One-time: create a signing certificate

macOS ties a Keychain "Always Allow" grant to the app's code signature. An ad-hoc signature has no stable identity, so the grant breaks on every rebuild and the app keeps re-prompting for access to the Claude Code credential. A self-signed certificate gives the app one stable identity, so the grant sticks.

Create the certificate once:

1. Open Keychain Access.
2. Choose Keychain Access > Certificate Assistant > Create a Certificate.
3. Name it `CC Usage Monitor Dev`, set Identity Type to Self-Signed Root, and set Certificate Type to Code Signing.
4. Click Create, then Done.

Keychain Access marks the certificate "not verified by a third party". That is expected for a self-signed certificate and changes nothing here: signing works, and the Keychain grant persists on the signature's identity. You do not need to trust the certificate.

The build script signs with this certificate by default. To use a different name, set `SIGN_IDENTITY` when you build:

```
SIGN_IDENTITY="My Cert Name" ./scripts/build-release.sh
```

## Build, install, and launch

Run the build script from the repository root:

```
./scripts/build-release.sh
```

It generates the Xcode project, builds the Release configuration, signs the app with your certificate, installs it to `/Applications/CCUsageMonitor.app`, clears the quarantine flag, and launches it. A menu bar item appears showing two donut rings: the current session on the left and the weekly all-models limit on the right, each with its percentage inside.

On the first build, macOS asks whether `codesign` may use the signing key. Choose Always Allow so later builds sign without prompting.

To install somewhere else, set `APP_DEST`:

```
APP_DEST="$HOME/Applications/CCUsageMonitor.app" ./scripts/build-release.sh
```

If the certificate is missing, the script warns you, signs ad-hoc, and continues. The app still runs, but it re-prompts for Keychain access on each rebuild until you create the certificate.

## Grant access

On first launch the app asks for two things:

- **Notifications.** Allow them so threshold alerts can fire. The Rules tab shows a banner while notifications are off, with a button that opens Settings.
- **Keychain.** On first launch the app asks once to read the Claude Code credentials item and once to write the refreshed token back. Choose Always Allow both times. With the certificate in place, these grants persist across launches and rebuilds, so you grant them once. The app never prompts from its background poll, so it cannot trigger a stream of dialogs: if the grant is ever lost, the window shows a Keychain message with a **Grant Access** button that re-prompts in place, and you do not relaunch.

The app writes back so it can refresh the token and keep Claude Code in sync when Claude Code is closed. It updates only the token fields and preserves everything else in the item.

## Credential source: file or Keychain

The app reads the subscription OAuth credential two ways and prefers the first it finds:

1. **File:** `~/.config/cc-usage-monitor/credentials.json`. A file read never prompts, so the app stays silent and the Keychain dialogs never appear. Prefer this when Claude Code authenticates with a `CLAUDE_CODE_OAUTH_TOKEN` env var, because it then stops maintaining the Keychain item, or when the Keychain item's access list breaks after a macOS update.
2. **Keychain:** Claude Code's `Claude Code-credentials` item, the path the Grant access section covers. The app uses this when the file is absent.

Seed the file once from the Keychain credential:

```sh
mkdir -p ~/.config/cc-usage-monitor
security find-generic-password -s "Claude Code-credentials" -a "$(id -un)" -w \
  > ~/.config/cc-usage-monitor/credentials.json
chmod 600 ~/.config/cc-usage-monitor/credentials.json
```

Approve the one Keychain dialog. The app then refreshes the token itself and writes each refresh back to the file, so it never reads the Keychain again.

The credential must carry the `user:profile` scope, which `claude /login` grants. A `claude setup-token` token will not work: it is inference-only, so the usage and profile endpoints reject it with a 403 scope error. If the file's refresh token expires, the window shows a sign-in message; run `claude /login`, then re-run the seed command above.

## Use

- The menu bar item shows two donut rings: the current session on the left and the weekly all-models limit on the right, each with its percentage inside. A ring turns amber at 80 percent and red at 90 percent, and both dim when the data is stale.
- Click the menu bar item to open the window. The **Usage** tab shows the current session, the two weekly limits, your plan tier, and usage credits. The **Rules** tab adds, lists, and deletes threshold alerts.
- Add a rule by picking a metric and a threshold from 1 to 99. The app notifies you once when the metric reaches the threshold, and re-arms only after the metric drops back below it.
- Rules persist in `~/Library/Application Support/CCUsageMonitor/notification-rules.json`.

## Quit

The menu bar item has no Quit command in this version. To quit, run `osascript -e 'quit app "CCUsageMonitor"'` or force-quit from Activity Monitor.

## Notes on distribution

This build is signed with your own self-signed certificate for local use on this Mac. Running it on another Mac would still trip Gatekeeper. Distributing it without that warning would require a Developer ID certificate and notarization from a paid Apple Developer account, which is outside the scope of this single-user app.
