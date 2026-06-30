# Install CC Usage Monitor

CC Usage Monitor is a menu bar app that shows your Claude Code usage and alerts you when a metric crosses a threshold you set. It runs as a menu bar accessory: no Dock icon, and it keeps running after you close its window.

## Requirements

- macOS 14 or later.
- Claude Code signed in on this Mac, so you can seed the app's credential from its login (see Credential source below). The app never asks you for a password.
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
- **Keychain.** Needed only on the fallback path, when the credentials file below is absent. The app reads the Claude Code credentials item read-only and never writes it. On the first read, choose Always Allow. With the certificate in place, the grant persists across launches and rebuilds. The app never prompts from its background poll: if the grant is ever lost, the window shows a Keychain message with a **Grant Access** button that re-prompts in place.

On the Keychain path the app reads but never refreshes or rewrites the item, so it cannot rotate Claude Code's shared session and sign it out. When the stored token expires, the app holds the last good data and shows it as stale until Claude Code refreshes the token on its next use. Claude Code also rewrites the item when it rotates its own token, which can drop the access grant and make the window ask for access again. The file path below avoids both problems.

## Credential source: file or Keychain

The app reads the subscription OAuth credential two ways and prefers the file when it exists:

1. **File (recommended):** `~/.config/cc-usage-monitor/credentials.json`. The file holds the monitor's own OAuth session. The app refreshes that session itself and writes each refresh back to the file, so it never reads the Keychain, never prompts, and never disturbs Claude Code.
2. **Keychain (fallback):** Claude Code's `Claude Code-credentials` item, used when the file is absent. The app reads it read-only and never refreshes it, so it shows stale data once the token expires, and a Keychain rewrite by Claude Code can make the window ask for access again.

Seed the file with a session of its own, separate from the one Claude Code uses. Copying Claude Code's live credential would share one refresh-token family, so the app's next refresh would rotate that token and sign Claude Code out. Give the monitor an independent session instead:

```sh
mkdir -p ~/.config/cc-usage-monitor

# 1. Refresh Claude Code's session.
claude /login

# 2. Copy that credential into the monitor's file.
security find-generic-password -s "Claude Code-credentials" -a "$(id -un)" -w \
  > ~/.config/cc-usage-monitor/credentials.json
chmod 600 ~/.config/cc-usage-monitor/credentials.json

# 3. Log in again so Claude Code moves to a new session and stops using the one in the file.
claude /login
```

After step 3 the file holds a session Claude Code no longer uses, so the monitor refreshes it freely while Claude Code stays signed in.

The credential must carry the `user:profile` scope, which `claude /login` grants. A `claude setup-token` token will not work: it is inference-only, so the usage and profile endpoints reject it with a 403 scope error. If the file's refresh token expires while the app is not running, the window shows a sign-in message; re-run the three steps above.

Only a rejected credential shows that sign-in message. A transient network or server error keeps the last good data, marks it stale, and lets the next poll retry, so a brief outage never signs you out.

## Use

- The menu bar item shows two donut rings: the current session on the left and the weekly all-models limit on the right, each with its percentage inside. A ring turns amber at 80 percent and red at 90 percent, and both dim when the data is stale.
- Click the menu bar item to open the window. The **Usage** tab shows the current session, the two weekly limits, your plan tier, and usage credits. The **Rules** tab adds, lists, and deletes threshold alerts.
- Add a rule by picking a metric and a threshold from 1 to 99. The app notifies you once when the metric reaches the threshold, and re-arms only after the metric drops back below it.
- Rules persist in `~/Library/Application Support/CCUsageMonitor/notification-rules.json`.

## Quit

The menu bar item has no Quit command in this version. To quit, run `osascript -e 'quit app "CCUsageMonitor"'` or force-quit from Activity Monitor.

## Notes on distribution

This build is signed with your own self-signed certificate for local use on this Mac. Running it on another Mac would still trip Gatekeeper. Distributing it without that warning would require a Developer ID certificate and notarization from a paid Apple Developer account, which is outside the scope of this single-user app.
